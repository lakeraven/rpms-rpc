# ADR 0005: Session-scoped broker clients — a pool, not one process-global session

**Status:** Proposed
**Date:** 2026-09-21
**Extends:** [ADR 0001 — Scope and no Rails coupling](0001-scope-and-no-rails-coupling.md)
**Closes:** rpms-rpc#234

## Context

`RpmsRpc.client` is a single process-global object holding **one** authenticated
RPMS session. Every concurrent request in a host app rides it. #235 (AV-code
encryption + wire lock) made each send/read pair atomic and serialized the
multi-RPC sign-on, closing the *response-crossing* defect. Two problems remain,
and they are the load-bearing ones:

1. **One client holds one broker identity.** A second sign-on re-binds that
   identity away from the first, so RPCs issued afterwards on behalf of the
   first user run as the second. On the surface that decides *who may read a
   chart* — lakeraven-ehr's per-request browser sign-on (#486) — that is a
   patient-safety and privacy defect, not a throughput one.
2. **Serialization turned the concurrency bug into a throughput ceiling.** Every
   RPC in the process queues behind every other.

This is the same defect family as #245 (a sign-on must not attest an identity it
did not resolve), lifted from one client to the shared-client level: *a broker
client must never serve a request under an identity other than the one the
caller authenticated.*

## Decision

Introduce **`RpmsRpc::SessionPool`**: a bounded pool of broker clients keyed by
an opaque session key. Each authenticated session gets its **own** client, which
stays bound to that one identity for its whole life in the pool.

```ruby
pool = RpmsRpc::SessionPool.new(
  max_sessions: 64,
  build: ->(session_key) { authenticated_client_for(session_key) }
)

pool.with_client(session_key) do |client|
  client.call_rpc("ORWPT SELECT", dfn)
end
```

Invariants (the security core):

- **One identity per client, for life.** A client built for session A is never
  handed to session B. There is no re-authenticate-in-place path, so there is no
  reset bug that can leak identity A into a B request. Isolation is structural,
  not a cleared field.
- **Concurrent same-session callers share the one client** (two tabs, one
  clinician). Correctness holds because the client already serializes its own
  wire (`synchronize_wire`), and both callers ARE the same identity.
- **Eviction only touches idle entries** (refcount 0) and **disconnects** the
  client before dropping it — never an in-flight one. LRU order.
- **Fail closed on exhaustion.** When the pool is full and every entry is in
  use, checkout raises `PoolExhaustedError` rather than silently reusing another
  session's client or blocking forever.

The `build` proc owns credentials and authentication; the pool owns only
lifecycle (reuse, capacity, idle eviction, shutdown). Keeping credentials out of
the pool keeps this gem free of host-app auth policy, consistent with ADR 0001.

`RpmsRpc.client` stays for genuinely process-global, single-identity paths
(background jobs, a single-tenant CLI, tests). Request-scoped code moves to the
pool. The rollout spans three layers, and only the first is this ADR:

1. **rpms-rpc (this ADR):** the `SessionPool` primitive and its invariants.
2. **lakeraven-ehr (the engine):** `RpcSupport.broker` — today
   `AuditedBroker.wrap(RpmsRpc.client)`, the one accessor every gateway reaches
   the broker through — becomes session-aware, pulling the caller's client from
   the pool instead of the global. This is the #486 per-request browser sign-on
   surface and the real consumer change.
3. **lakeraven-ehr-saas (the Rails host):** owns the request/session lifecycle,
   so it instantiates the pool, derives the pool's session key from the
   authenticated web session, and composes per-session isolation with the
   per-tenant scoping tracked in lakeraven-ehr-saas#29 (`require_tenant`). Its
   own live-backend `Broker` routes through the pool on the same path.

Each layer is its own PR against its own repo; this one ships the mechanism the
other two build on.

## The forks left open for agreement

These are policy, not correctness, and are surfaced deliberately rather than
hard-coded:

1. **Keying.** We key by an opaque session key supplied by the host (in
   lakeraven-ehr, the #486 session→token bridge id). Alternative: key by DUZ.
   Session-key is safer — two logins by one clinician stay isolated and a
   logout evicts cleanly — at the cost of more clients. **Recommend session-key.**
2. **Sizing / exhaustion policy.** First cut: fixed `max_sessions`, raise on
   exhaustion. Alternatives: block-with-timeout, or auto-grow. Raise is the
   fail-closed default; revisit with real concurrency numbers from the pilot.
3. **Idle eviction trigger.** This ADR evicts lazily (on checkout when capacity
   is needed). A background reaper (evict clients idle > N minutes to free broker
   sessions proactively) is a later addition if broker session limits bite.

## Consequences

- The who-reads-a-chart path gets structural identity isolation; #234's re-bind
  defect cannot occur because no client is ever re-bound.
- Throughput scales with distinct active sessions instead of serializing the
  whole process onto one socket.
- Host apps must thread a session key through request-scoped RPC calls — a real
  but appropriate cost, since the alternative is an unauthenticated global.
- Rejected: a checkout/checkin pool that re-authenticates a shared client per
  checkout. It re-introduces the exact #245/#234 risk (a client momentarily
  holding the wrong or a stale identity) and pays a per-request sign-on cost.
