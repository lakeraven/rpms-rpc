# ADR 0010: The consumer contract

**Status:** Proposed
**Date:** 2026-10-03
**Relates to:** [ADR 0001](0001-scope-and-no-rails-coupling.md) (scope), [ADR 0005](0005-session-scoped-broker-clients.md) and [ADR 0006](0006-request-scoped-client-resolution.md) (clients), [ADR 0008](0008-nothing-in-the-gem-without-rpms-behind-it.md) (nothing without RPMS behind it), [ADR 0009](0009-live-specs-against-a-disposable-container.md) (live specs)

## Context

The gem exists so that new web applications can be built on RPMS.
A host application treats RPMS as a backing service, in the twelve-factor sense: attached by configuration, reached over the network, replaceable by another deploy of the same build.

Today the boundary between the gem and a host is wide and partly implicit.
A host calls module functions against one process-global client, calls the gem's authorization helpers from its models and policies, and in places sends raw RPC names, builds M parameter strings and splits `^` pieces itself.
The gem, for its part, ships policy (keys mapped to roles and capabilities), a FHIR client, and an in-memory fake of RPMS that hosts test against.

Under ADR 0009 every method the gem exposes is proven by a live call against the pinned build.
That proof is only worth something to a host if the host reaches RPMS through those methods and nothing else.
This ADR states the contract both sides can rely on.

## Decision

### The contract the gem offers

Each assertion is checkable, and names how.

1. **Real.** Every RPC a public method sends is callable on the pinned build: registered, with an entry point, active, and its reach class `client-callable` or `broker-exempt` in the build's published reach face.
   *Checked by* the build-signature conformance gate (ADR 0008, #330) and the callable gate (`test/rpms_rpc/callable_rpc_names_test.rb`, #394). A build defect that breaks one is recorded with its issue in `data/fingerprints/uncallable_exceptions.yml` and printed on every run.
2. **Proven.** Every public method has a live spec that passes against a fresh container of the pinned build, as the least-privilege persona and as the programmer persona, or names the persona it requires.
   A method without one is not part of the contract.
   *Checked by* `rake test:live` (ADR 0009) and a coverage report listing public methods without a live spec.
3. **Facts, not policy.** Methods return what RPMS answered: Ruby hashes and arrays with typed values (Integer IENs, `Date`/`Time`, `String`), `nil` for "none", `[]` for "no rows".
   The gem reports which security keys a user holds and whether the server lets a user run an RPC.
   It does not map keys to roles, capabilities or permissions.
   *Checked by* the live specs' shape assertions, and by the absence of role or capability vocabulary in `lib/`.
4. **Failures are explicit.** A refusal, an M error, an unregistered RPC, a lost connection and a timeout each raise a typed exception under one `RpmsRpc::Error` base.
   Error text is never returned as data; an error is never returned as `nil`.
   Messages never contain credentials.
   *Checked by* live specs that provoke each failure, and the sanitisation tests.
5. **No ambient state.** Public methods act on the client the host hands them (ADR 0006).
   Methods read no environment variables and no process-global configuration.
   The process-global client remains only for the console, scripts and jobs.
   *Checked by* a test that loads the API with no global client configured and calls it with an explicit one.
6. **One client per user session.** A signed-on client carries one user's identity and context and is never shared across users.
   The gem provides the pool that keys clients by session (ADR 0005).
7. **No host knowledge.** No Rails, no HTTP, no FHIR, no UI concepts (ADR 0001, ADR 0008 §6).
   The FHIR client and any host-shaped helpers leave the gem.
8. **Typed methods are the integration path.** `client.call_rpc` with a raw RPC name is for exploration: the console, the contract sweep, diagnostics.
   A host that needs an RPC the gem does not expose asks for a typed method, which arrives with its live spec.
9. **Configuration is supplied, never assumed.** The host supplies the broker protocol, host and port, and each user's access and verify codes at sign-on.
   The gem has no default host, port or credential outside development, and fails with a message naming what is missing.
10. **Releases say what they were proven against.** Each release names the pinned build its live specs passed on.
    Removing a method or changing a return shape is a breaking change under semantic versioning, listed in the CHANGELOG with the replacement, if any.

### What a host does on its side

These are the consequences for any host, stated as the shape the gem is designed for.

1. **One port.** All RPMS access goes through the host's own adapter layer, which depends only on the gem's public API.
   Nothing outside that layer references the gem.
2. **The host owns policy and presentation.** Roles, capabilities, tenancy, FHIR resources and UI are derived by the host from the facts the gem returns.
3. **The host tests its own logic against its own port.** Unit tests replace the host's adapter layer with a test double of the host's own design.
   They do not fake RPMS.
   Integration is covered by a small set of application-level tests against a container of the same pinned build the gem was proven on.
4. **Configuration from the environment, clients per session.** The host reads broker settings from its environment, signs each user on with their own codes, and resolves a client per request from the session pool.

### The in-memory fake

`MockClient` / `RpmsRpc.mock!` is a fake of RPMS shipped as part of the gem.
It is deprecated as a host test double: under host rule 3 a host fakes its own port, not RPMS.
It is removed in a later release, once no host depends on it, and is not extended in the meantime.

## Consequences

### Positive

- The live specs that prove the gem become the guarantee a host relies on; there is one place where "RPMS answers this way" is decided.
- A host's tests stop encoding beliefs about RPMS, and a host's unit tests no longer need the gem's internals.
- Hosts become deployable against any instance of the pinned build by configuration alone.

### Negative

- Breaking changes for current hosts: removed methods (unregistered RPCs, policy helpers, the FHIR client), changed shapes, and an explicit client in place of the ambient one.
- Hosts that send raw RPCs today need typed methods first; until then that traffic is outside the contract.
- Work in the gem: one error base class, a coverage report of public methods without live specs, the explicit-client sweep (#234), and the removals.

### Alternatives considered

- **Keep policy in the gem** (keys to roles and capabilities). Rejected: role meaning differs per host and per site, and it cannot be proven by a live call; it is a host decision.
- **Keep the fake as the host test double, made faithful to RPMS** (#232, #255). Rejected as the default: it makes the gem maintain a second, simulated RPMS that live specs cannot check; a host's own port is the cheaper and more honest seam.
- **Expose raw RPC access as a supported path.** Rejected: it moves M parameter building and `^` parsing into every host, where nothing proves it.

## References

- #234 (explicit clients), #350 (tests against real RPMS), #318 (held keys), #314 (security keys that exist), #207 / #295 (only real RPCs), #222 / #330 (build signature).
