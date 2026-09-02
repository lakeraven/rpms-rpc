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

## Patient registration (composed)

`RpmsRpc::Patient.register` / `RpmsRpc::Registration` compose these RPCs to
replace the retired `BHDPTRPC REGISTER` placeholder. All are LIST-param RPCs;
the reply shapes are parsed by `RpmsRpc::DdrFileman`. Wire grammar and the
identity-guard read were live-verified end to end against `rpms-ydb-9.0`
(2026-09-02). See `RpmsRpc::Registration` for the KNOWN DIVERGENCES from
AG-native registration (no HRN-uniqueness enforcement, no HL7 staging, no AG
procedural checks).

| RPC name                | Routine / Tag        | Params (LIST subscripts)                     | Return                                  | Status   |
|-------------------------|----------------------|----------------------------------------------|-----------------------------------------|----------|
| `VAFC VOA ADD PATIENT`  | `ADD^VAFCPTAD`       | PRFCLTY/NAME/GENDER/DOB/SSN/SRVCNCTD/TYPE/VET/FULLICN | `1^DFN` / `-1^error`            | verified |
| `DDR FILER`             | `FILEC^DDR3`         | MODE, DDRROOT rows, FLAGS, DDRIENS           | `[Data]`+`+n,^IEN` / `[BEGIN_diERRORS]` | verified |
| `DDR LISTER`            | `LISTC^DDR`          | FILE/IENS/FIELDS/FLAGS/MAX/FROM/PART/XREF/... | `[Data]`+rows / `[Misc]`+`MORE^..`       | verified |
| `DDR LOCK/UNLOCK NODE`  | `LOCKC^DDR1`         | NODE, LOCKMODE, TIMEOUT                       | `1` acquired / `0` timeout               | verified |
| `DDR GETS ENTRY DATA`   | `GETSC^DDR2`         | FILE/IENS/FIELDS/FLAGS                        | `[Data]`+field rows / `[ERROR]`          | verified |
| `DDR VALIDATOR`         | `VALC^DDR3`          | FILE/IENS/FIELD/VALUE                         | `[FILLER]`/`[Data]`+internal/external    | verified |

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
