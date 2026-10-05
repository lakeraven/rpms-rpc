# ADR 0009: Live specs against a disposable container

**Status:** Proposed
**Date:** 2026-10-03
**Relates to:** [ADR 0003](0003-test-first-rpc-additions.md) (amends its captured-reply merge gate), [ADR 0008](0008-nothing-in-the-gem-without-rpms-behind-it.md) (gives its rule 4 a harness), #346, #347, #348

## Context

The aim is complete coverage of what RPMS serves, its RPCs and its other
programmatic surfaces, so that new web clients can be built on it.

Most defects found in this gem have been wrong beliefs about the server: a
date typed internal that RPMS sends external, a reply framing the client did
not read, an RPC a user's context does not allow. Tests built from replies
we wrote, or from replies a server once sent, encode the belief and pass.
A recorded capture proves only that the client parses bytes it was given; it
cannot see the server change.

The YottaDB image of a pinned build is license-free. A fresh `docker run` of
it is a clean, reproducible RPMS: the container is the snapshot. Writes become
testable because the container is thrown away.

## Decision

### Coverage has four layers, reported separately

1. **Inventory.** Every RPC the build registers is accounted for: callable,
   or excluded with a reason (the pinned build signature, #330 and
   rpms-ops#713; the exclusions, #323, generated from the pinned reach face, #394).
2. **Contract.** A generated live sweep makes one safe read call per callable
   RPC from its `#8994` input parameters and RETURN VALUE TYPE, and records the
   reply's shape per build and persona (#348). Its output is the build's
   contract catalogue, stored in lakeraven/rpms-diffs as evidence for client
   builders. It is not a test. `rake wire:capture` output moves there (#347).
   Writes are not swept; they enter at layer 3.
3. **Client API.** The gem's mappings, for the RPCs clients use. Each is
   proven by a live spec.
4. **Data surfaces.** FileMan through the DDR RPCs, and the BMW SQL projection.

Coverage is reported per layer: accounted for, contract known, typed in the gem.

### Live specs prove layer 3

- A live spec is a Ruby test in `test/live/` that calls the gem's public API
  over the wire against a fresh container of the pinned build. `rake test:live`
  runs them; `rake test` does not.
- It asserts shape and invariants, not demo-data values. Data it needs, it
  makes through a registered RPC and removes afterwards.
- It runs once per persona: the least-privilege PROV123 (the headline) and the
  programmer SYS123. A spec binds the context the RPC's package serves it under.
- A spec that writes declares so, and fails closed unless the target is
  declared disposable and on this machine.
- **A read or write mapping change is done only when a live spec proves it.**
  Run live before merge (locally, or by an agent against the local container),
  and nightly in CI if the image can run there.
- IRIS needs a license, so IRIS live runs use a local licensed container or an
  AWS stack, and never write to a shared stack.

### What hand-written replies are still for

Client mechanics no server produces on demand: broker framing, error and
refusal channels, parameter encoders, credential sanitising. Those tests
exercise our code, not RPMS, and say which mechanic they cover.

### What this changes in ADR 0003

ADR 0003 §2 required a mapping to be contract-tested against a captured,
sanitized real reply before merge. That requirement is replaced by a live spec.
Its ordering (contract evidence, then a failing test, then the mapping) stands;
the failing test is a live spec where a container can serve it.

## Consequences

### Positive

- A green spec means the pinned build answers that way, as that user.
- Writes get tested, which no capture could do.
- The first spec found a framing defect the fabricated test hid: on CIA a
  global-array reply has no line breaks, and `hospital_locations` returned the
  typed header as its only row.

### Negative

- Live specs need a broker: a local container of the pinned image, or a stack
  over an SSM tunnel. `rake test:live` fails without its settings rather than
  skipping, and a run in which no live spec ran is never green; but `rake test`
  does not run them, so a merge can still land unproven unless review asks for
  the live run's summary.
- CI runs only if an image for the runner's architecture exists (only arm64 is
  known locally).
- Legacy wire-capture tests stay until live specs cover their RPCs (#347).

### Alternatives considered

- **Recorded cassettes replayed in CI.** Fast and offline, and blind to the
  server: the failure this ADR exists to stop.
- **A long-lived shared stack.** Not reproducible, and writes would corrupt it.

## References

- `test/live/live_helper.rb` — the harness
- `tools/rpc_coverage/live_runner.rb` — `rake rpc:live`, which converges with the live specs (#347)
- #221 — the first spec's subject (BSDX HOSPITAL LOCATION dates)
