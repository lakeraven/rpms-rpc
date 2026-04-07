# Verified RPCs

Per [ADR 0002](adr/0002-verified-routine-policy.md), every RPC the
gem speaks to must be verified against actual MUMPS source in the
[CIVITAS FOIA-RPMS](https://github.com/CivicActions/FOIA-RPMS)
repository before merge.

This file is the audit trail. It lists every RPC name the gem invokes,
the FOIA-RPMS routine that implements it, the parameter shape, and the
return format.

## Authentication & session

| RPC name              | Routine / Tag           | Params              | Return                          | Status     |
|-----------------------|-------------------------|---------------------|---------------------------------|------------|
| `XUS SIGNON SETUP`    | `XUS^XUSRB`             | none                | array of environment lines      | verified   |
| `XUS AV CODE`         | `AVCODE^XUSRB`          | encrypted "AC;VC"   | DUZ + status lines (CRLF/NL)    | verified   |
| `XWB CREATE CONTEXT`  | `CREATE^XWBSEC`         | encrypted option    | "1" on success, error otherwise | verified   |

**Notes:**

- `XUS SIGNON SETUP` is a no-arg call that returns the broker's
  signon environment. It is required before `XUS AV CODE`.
- `XUS AV CODE` requires the access/verify codes to be passed
  through the `xwb_encrypt` cipher (`$$ENCRYP^XUSRB1`).
- `XWB CREATE CONTEXT` is sent the option name through the same
  cipher and gates whether RPCs in that context can be invoked.

## Conventions

When new RPCs are added to the gem in downstream consumers
(`lakeraven-ehr`, etc.), they must add a row to this table along
with the verifying FOIA-RPMS path before the consumer ships.

The base `RpmsRpc::Client` ships with **only** the routines required
for connection lifecycle and authentication. Domain-specific RPCs
(patient lookup, consult lists, allergies, lab results) live in the
consuming application — `rpms-rpc` is the wire layer, not a domain
client.

## Unverified RPCs

None. The gem refuses to merge an RPC call that has not been verified
against M source per ADR 0002.

## See also

- [ADR 0001 — Scope and no Rails coupling](adr/0001-scope-and-no-rails-coupling.md)
- [ADR 0002 — Verified routine policy](adr/0002-verified-routine-policy.md)
- FOIA-RPMS XWBTCPM.m — XWB/CIA wire protocol
- FOIA-RPMS BMXMON.m, BMXMBRK.m — BMX wire protocol
- FOIA-RPMS XUSRB.m, XUSRB1.m — signon and cipher
