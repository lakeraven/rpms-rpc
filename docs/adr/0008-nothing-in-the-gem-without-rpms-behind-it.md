# ADR 0008: Nothing in the gem without RPMS behind it

**Status:** Proposed
**Date:** 2026-10-02
**Relates to:** rpms-rpc#207, #295 (unregistered RPC names), #255 (the mock should refuse what a server refuses), #222 (evidence provenance), [ADR 0002](0002-verified-routine-policy.md), ADR 0007 (each RPC through its own broker, proposed alongside this one)

## Context

This gem is a client for a system that already exists. Its job is to call what
RPMS serves, the way RPMS serves it, and to prove that against a running
instance. It is not a place to describe the API we wish RPMS had.

Three audits found the gem naming things RPMS does not have. Each survived
because the mock answered it.

| What the gem named | Checked against | Result |
|---|---|---|
| 268 RPC names | The RPC registry (`#8994`) of a built 9.0 YottaDB image and a built 9.0 IRIS image | 77 are in neither (#207, #295) |
| `ORWU USERKEYS`, "list a user's security keys" | The same registries and the routine it would live in | No such RPC and no such entry point. RPMS answers the question the other way round: a client names keys and asks which the user holds (`ORWU HASKEY`, and the chart's `HASKEYS` calls) |
| 13 names in `SecurityKeys::REGISTRY` | The SECURITY KEY file (`#19.1`) of a built image | 1 is a key. 10 exist nowhere on the image and 2 are option names, not keys |
| A user-class number on the sign-on reply, mapped to roles | The sign-on routine | That line of the reply is a message count (#236) |

The intention behind each was reasonable. The name was a guess, a mock was
seeded to match the guess, and the tests passed.

## Decision

1. **Every name the gem sends to RPMS, or expects from it, exists on a built
   image.** That covers RPC names, context option names, security key names,
   file and field numbers. A name with no evidence is not added.
2. **Each kind of name has a committed list and a test that fails on a name
   outside it.** RPC names have one (`data/rpc_coverage/registry/`, the test
   added with #207). Option names and key names get the same.
3. **A function exists only to call something RPMS serves.** A method whose RPC
   is not registered is deleted, not kept behind a capability check that quietly
   returns nothing. If the need is real, the gem finds how RPMS answers it and
   maps that.
4. **Registered is the floor.** A mapping is done when a live call on its home
   broker has answered with the layout the mapping declares: first as a
   programmer-key user, which proves the RPC and its shape, then as a user who
   holds only that role's context and keys, which proves access.
5. **The mock refuses what a server refuses:** an RPC that is not registered, an
   RPC the bound context does not serve, a locked option without its key.
6. **What is not an RPC client does not live here.** Role policy and non-RPC
   transports belong to the application that needs them, or to their own gem.

## Consequences

### Positive

- A green test means RPMS does this, not that the mock was told to.
- The gem's size is the size of what has been proven.

### Negative

- The public surface shrinks, and consumers break when they move their pin.
  Each removal lists the callers it affects.
- Some needs have no stock answer (a "list my keys" call, an inpatient movement
  write). Those become stated gaps rather than plausible methods.

### Alternatives considered

- **Keep unproven methods, marked provisional.** Tried: a provisional mapping
  still passes its mock-backed test and still gets called.
- **Gate on capability probes.** Tried: the probe hid the missing RPC as
  "not supported on this server", which reads the same as a real absence.

## To do under this ADR

- Remove the 12 names in `SecurityKeys::REGISTRY` that are not security keys,
  with a key-name list and a guard test.
- Decide where `UserRoles` and `FhirClient` go (rule 6).
- Give option names the same list and guard.
