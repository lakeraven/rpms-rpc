# ADR 0006: How request-scoped code gets its broker client

**Status:** Proposed
**Date:** 2026-09-22
**Extends:** [ADR 0005 — Session-scoped broker clients](0005-session-scoped-broker-clients.md)
**Relates to:** rpms-rpc#234 (the half ADR 0005 left unspecified)

## Context

ADR 0005 built `SessionPool` and stated the principle: *"`RpmsRpc.client` stays
for genuinely process-global, single-identity paths. Request-scoped code moves
to the pool."* It did not say **how** request-scoped code obtains a client. That
sentence is the whole remaining cost of #234, and nothing in the API layer has
moved.

The pool now exists and works (#250 built it; #252 added `adopt` so sign-on's
already-authenticated client binds to a session without a second sign-on). No
caller in `lib/rpms_rpc/api/` uses it.

### The actual blast radius

Two paths reach the global, and the second is easy to miss:

1. **Direct** — `RpmsRpc.client.call_rpc(...)` in **22** API modules.
2. **Indirect** — `DataMapper`'s `fetch_one` / `fetch_many` / `fetch_scalar` /
   `fetch_text` / `fetch_lines` each call `RpmsRpc.client` internally
   (`data_mapper.rb:266-294`). **48** API modules call those.

The union is **51 of 52 modules**; 19 use both routes. A change that fixes only
`api/*.rb` fixes roughly half the problem and leaves the rest reaching the
global through `DataMapper`. `DataMapper` must move in the same change or the
work is not done.

### Why this is not a mechanical sweep

The API layer is `module X; extend self; end` module-functions with no receiver
to hold state. There is nowhere to put a client without changing either the
signature, the call shape, or introducing ambient state. That is an API-shape
decision with consumers in `lakeraven-ehr` (`RpcSupport.broker`) and
`lakeraven-ehr-saas`, so it wants agreement before a 51-module diff, not after.

### The invariant that has to survive

From ADR 0005, and it is the reason #234 exists: **a broker client must never
serve a request under an identity other than the one the caller authenticated.**
ADR 0005 earned that structurally — "isolation is structural, not a cleared
field." Whatever shape we choose should hold the same standard: a caller that
forgets to supply a session must **fail**, not quietly fall back to a global
holding someone else's identity. Silent fallback is the identity-bleed defect
wearing a different hat.

## Options

### A. Explicit client parameter

```ruby
Allergy.assessment(dfn, client: client)
DataMapper[:allergy_list].fetch_many(dfn, client: client)
```

Structural and obvious; no ambient state; trivially testable. But it is viral —
every public method, every `DataMapper` fetch, and every intermediate helper
grows a parameter, and every consumer call site changes. It is a breaking change
to the gem's whole surface, and most methods would only thread the value through
to `call_rpc`.

### B. Ambient scoped context

```ruby
RpmsRpc.with_session(session_key) do
  Allergy.assessment(dfn)          # resolves the scoped client
end
```

`RpmsRpc.client` resolves to the fiber-local scoped client when one is set.
Smallest diff by far: `DataMapper` and all 51 modules keep their current shape
and are fixed by changing one resolver.

The danger is the fallback. If an unwrapped caller silently gets the process
global, we have re-created #234 with better ergonomics — and it would pass tests,
because tests configure a global. **This option is only acceptable with a strict
mode that raises when no session is in scope**, with the global reachable solely
through an explicit opt-in (`RpmsRpc.global_client`) that request paths never
call. Ambient state also crosses threads/fibers badly: any `Thread.new` inside a
scope loses it, which must be documented and tested, not discovered.

### C. Scoped-API facade over the existing modules

```ruby
scope = RpmsRpc::ScopedApi.new(pool, session_key)   # holds pool + key, NOT a client
scope.allergy.assessment(dfn)
scope.lab.results(dfn)
```

`ScopedApi` exposes the API modules with a client threaded through; the modules
keep their logic but take the client explicitly (internally, as in A).
Structurally impossible to call without a client — the property ADR 0005 chose
for the pool itself. Cost: a facade covering 52 modules, and consumers move from
`Allergy.assessment(dfn)` to `scope.allergy.assessment(dfn)`.

**Naming.** Not `Session`: `RpmsRpc::Session` is already the cold-launch
bootstrap API (`lib/rpms_rpc/api/session.rb:8`), so a class of that name is a
constant conflict. `ScopedApi` is a placeholder — the name is open.

**Lifetime — the part that must not be gotten wrong.** The facade must hold the
**pool and the session key**, never a checked-out client. `SessionPool` pins an
entry only for the duration of a `with_client` block (`session_pool.rb:71-79`:
checkout, yield, checkin). A facade that retained a raw client between calls
would sit at refcount 0, look idle to LRU eviction and `shutdown`, be
disconnected, and then keep issuing RPCs on a dead socket — which is precisely
the defect #252 fixed, reintroduced one layer up. So each facade operation
acquires the client through `with_client` for the length of that operation:

```ruby
def call(rpc_name, *params)
  @pool.with_client(@session_key) { |client| client.call_rpc(rpc_name, *params) }
end
```

A multi-RPC sequence that must not interleave (sign-on, anything spanning more
than one call) takes an explicit bounded lease instead — one `with_client` block
around the whole sequence — rather than one pin per call. `SessionPool` has no
`session`/factory method today; whether the facade is constructed directly or
minted by the pool is an open question below.

## Decision

**Recommend C, with A's explicit parameter as its internal mechanism, and B
rejected as the end state.**

Reasoning: ADR 0005 chose structural isolation over convention for the pool and
gave the reason — a cleared field is a reset bug waiting to happen. B is that
same convention risk moved up a layer: correctness depends on every request path
remembering to wrap, and the failure mode is silent identity reuse on the code
path that decides who may read a chart. Strict mode makes B defensible, but it
buys a smaller diff at the cost of the property we said we wanted.

C keeps the 51 modules' logic untouched — the diff is a facade plus a threaded
parameter, not 51 rewrites — while making "no session, no call" a type-level
fact rather than a review checklist item.

**A facade alone is not the guarantee.** The API modules stay directly callable,
so `Allergy.assessment(dfn)` would still resolve the global and bypass the
facade entirely. The structural claim only holds if the rollout *also* makes
every request-facing entry point client-required — the module functions and the
`DataMapper` fetch helpers take the client explicitly (option A's mechanism),
and no request-facing path retains a global-backed signature. The facade is
ergonomics over that enforcement, not a substitute for it. A rollout that adds
the facade while leaving the global-backed entry points callable has not closed
#234.

`RpmsRpc.client` is **not** deleted. It stays for genuinely single-identity
process-global paths (background jobs, single-tenant CLI, tests), which is what
ADR 0005 said. What changes is that request-scoped code can no longer reach it —
enforced by signature, not by convention.

## Answers (2026-09-23)

**1. Consumer-side churn: acceptable.** The ADR assumed C changes "every call
site in `lakeraven-ehr`". Measured, it is **86 call sites across 25 files, and
20 of those files are `app/gateways/`** — one architectural layer, not a sprawl.
The gateway layer already exists as the RPMS boundary, which makes it the
natural holder of the scope. Churn concentrated in a layer that exists to be
that boundary is the cheap kind. Option B-with-strict-mode is **not** taken.

**2. Staged — but across a version boundary, not inside one codebase.** A mixed
state where both the old and new paths work is exactly where a request path
silently keeps the global, so staging by tier is rejected. Instead:
PR 1 (gem) adds the required client parameter to `DataMapper` and the modules
*and* the facade together, released as a version bump; PR 2 updates
`lakeraven-ehr` on that bump. The version boundary enforces what tier-staging
could not — the same shape #519 used to take rpms-rpc 0.3.0.

**3. `DataMapper` takes the client explicitly.** It is the chokepoint: 48 of 52
modules reach the global *only* through `fetch_one/many/scalar/text/lines`, so
fixing `DataMapper` closes the indirect path for all of them in one move,
leaving 22 direct users to update by hand. #254 reinforces this — three
surfaces now need global-array decode (`Agg`, `Patient`, `Scheduling`), and a
decode copied a third time belongs in `DataMapper` too. The same chokepoint
argument answers both.

**4. Signatures, not warnings.** A deprecation warning is a convention, and
this ADR's whole argument is that convention is what fails here. `RpmsRpc.client`
stays for genuinely single-identity process-global paths (background jobs,
single-tenant CLI, tests) and is not deprecated; what changes is that no
request-facing signature can reach it. Unreachable beats warned.

**5. Minted by the pool: `SessionPool#scope(session_key)`, returning
`RpmsRpc::ScopedApi`.** The load-bearing invariant is that the facade holds the
pool and the key and never a checked-out client; minting it from the pool makes
the wrong construction unavailable rather than merely discouraged. `Session` is
taken by the cold-launch bootstrap API (`api/session.rb:8`), so `ScopedApi`
stands unless something better surfaces during implementation.

**6. Per-operation `with_client` by default; explicit lease on four surfaces.**
Any sequence whose correctness spans more than one RPC takes one block around
the whole sequence:
- **sign-on** — already holds the wire for the multi-RPC sequence
- **AGG registration** — ADD then GETS against the same identity
- **DDR FILER sequences** — #241 is literally "broker session should survive two
  DDR FILER calls"; that is this lease, and the issue predates this ADR
- **TIU note create-then-sign**

Everything else is a single RPC and takes the per-operation pin.

## Open questions as originally posed

1. **Is the consumer-side churn acceptable?** C changes every call site in
   `lakeraven-ehr` from `Allergy.assessment(dfn)` to
   `session.allergy.assessment(dfn)`. If that is too much at once, B-with-strict
   -mode is the pragmatic alternative and should be chosen deliberately, not by
   default.
2. **One PR or staged?** 51 modules is a large diff to gate. Staging by tier
   (ADR 0004's MVC tiers) is possible but leaves the codebase in a mixed state
   where both paths exist — and a mixed state is exactly where a request path
   silently keeps the global.
3. **Does `DataMapper` get a client parameter, or does the facade wrap it too?**
   The fetch helpers are used directly by API modules and by consumers.
4. **Deprecation posture for `RpmsRpc.client`.** Warn on use from a
   request-scoped context, or rely on the signatures making it unreachable?
5. **Facade construction and name.** Direct (`ScopedApi.new(pool, key)`) or
   minted by the pool (a new `SessionPool#scope`)? And what is it called, given
   `Session` is taken?
6. **Lease granularity.** Per-operation `with_client` is the safe default, but
   any caller whose correctness spans several RPCs needs one block around the
   sequence. Which API surfaces need an explicit multi-RPC lease?

## Consequences

### Positive
- Closes the remaining half of #234: no request-scoped path can reach a client
  it did not authenticate.
- The pool built in #250/#252 gets its first real consumer; today it is a
  primitive nothing calls.
- `DataMapper`'s hidden dependency on global state becomes explicit.

### Negative
- A large, wide diff across 51 modules and their consumers, landing in a repo
  whose value is its verified RPC surface.
- Consumers in `lakeraven-ehr` and `lakeraven-ehr-saas` must change in step;
  this is layers 2 and 3 of ADR 0005's rollout and cannot lag far behind.

### Alternatives considered
- **B without strict mode** — rejected. Silent fallback to a global under a
  different identity is the defect #234 was filed for.
- **Leaving the API layer on the global and pooling only at the host-app
  boundary** — rejected. It puts the security-critical decision in every host
  app rather than in the gem that owns the broker contract.

## References
- ADR 0005 — Session-scoped broker clients
- rpms-rpc#234 — the originating defect
- rpms-rpc#250, #252 — the pool and its `adopt` handoff
- `lib/rpms_rpc/data_mapper.rb:263-294` — the indirect path to the global
