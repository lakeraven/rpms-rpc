# ADR 0002: Verified routine policy

**Status:** Accepted
**Date:** 2026-04-06

## Context

VistA/RPMS exposes RPC calls via routines stored in MUMPS source code.
The CIVITAS-maintained FOIA-RPMS distribution contains the canonical
M-language sources. RPC routines have specific tag names, parameter
shapes, and return formats that change rarely but **do change** between
RPMS releases.

In a previous codebase (`rpms_redux`), we discovered that several RPC
calls were written against mocked responses without verifying against
the actual M routine source. When deployed against a real RPMS instance,
these calls failed because the assumed parameter order or return shape
was wrong.

## Decision

Every RPC call shipped in `rpms-rpc` must be **verified against the
actual M source** in the CIVITAS FOIA-RPMS repository before merge.

Verification means:

1. The routine name and tag exist in the FOIA-RPMS source
2. The parameter list matches the documented input types
3. The return format (caret-delimited string, array, XML) matches
   what the parser expects
4. The verification is documented in `docs/rpcs.md` with the
   FOIA-RPMS path or routine reference

PRs adding new RPC calls must include:
- The M source reference in the PR body
- A test that exercises the parser against a fixture taken from
  real RPMS output (not invented)

PRs that cannot verify against M source must be marked
`@unverified` in `docs/rpcs.md` and excluded from any "production-safe"
manifest.

## Consequences

### Positive
- Reduces "works in mock, breaks in production" failures
- Creates an auditable trail of which RPCs are real and which are guesses
- Forces engineers to read the actual MUMPS code, building tribal
  knowledge of how RPMS is structured

### Negative
- Verification takes longer than mocking
- Some legacy RPCs in rpms_redux may be unverified — they need backfill
  or removal during the port
- Contributors without FOIA-RPMS access cannot verify, limiting external
  contributions to docs and bug fixes

### Alternatives considered
- **Trust mocks, fix in production.** Rejected — we already learned this
  lesson the hard way in rpms_redux.
- **Verify only on first use.** Rejected — by then it's deployed
  somewhere, and rolling back is harder than verifying upfront.

## References
- CIVITAS FOIA-RPMS: https://github.com/CivicActions/FOIA-RPMS
- `docs/rpcs.md` — verified routine list
- ADR 0001: Scope and no Rails coupling
