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
| `XUS SIGNON SETUP`    | `SETUP^XUSRB`           | none                | array of environment lines      | verified   |
| `XUS AV CODE`         | `VALIDAV^XUSRB`         | encrypted "AC;VC"   | DUZ, XUM, VCCH, message, 0, post-sign-on message count, then the message lines (XUSRB.m:9-11, :40, :85-87) | verified   |
| `XUS GET USER INFO`   | `USERINFO^XUSRB2`       | none                | DUZ, name, standard name, division, title, service/section, language, DTIME (XUSRB2.m:25-35) | verified   |
| `XWB CREATE CONTEXT`  | `CREATE^XWBSEC`         | encrypted option    | "1" on success, error otherwise | verified   |

**Notes:**

- `XUS SIGNON SETUP` is a no-arg call that returns the broker's
  signon environment. It is required before `XUS AV CODE`.
- `XUS AV CODE` requires the access/verify codes to be passed
  through the `xwb_encrypt` cipher (`$$ENCRYP^XUSRB1`).
- Neither reply carries a user class. `XUS AV CODE` line 5 is the
  post-sign-on message count (it was read as a class until #236), and
  `XUS GET USER INFO` line 7 is DTIME. The user's class, `Authentication.user_type`, is
  read from `ORWU USERINFO` piece 3, USRCLS, which the server computes from
  ORES/ORELSE/OREMAS (ORWU.m:19).
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

### BHDPTRPC provenance (historical — family fully removed)

> The BHDPTRPC family (and its "8 RPCs" count) had **no traceable source**: it was
> introduced without citation in commit 7108ec5 — the same authoring pass whose
> ORWPT ID INFO field layout was proven hallucinated and fixed in 3f76849, which then
> relocated the disproven demographic fields to "BHDPTRPC (not installed on staging)".
> The family appears nowhere in the 65,782-routine FOIA corpus, the staging fingerprint
> (`data/fingerprints/staging-2026-06-07.yml`), or IHS public RPC documentation
> (issue #184). Every wire name in the family is now **removed** and replaced by
> verified paths:
>
> - registration → `VAFC VOA ADD PATIENT` + the DDR FileMan family
>   (`RpmsRpc::Registration.register`; contracts cited routine-by-routine in
>   rpms-ops `docs/REGISTRATION_RPC_CONTRACTS.md`)
> - patient update → `DDR FILER` / `FILE^DIE` under the `^DPT(DFN)` lock
>   (`RpmsRpc::Registration.update`; `EDIT^VAFCPTED` has no `^XWB(8994)`
>   registration on any observed target)
> - tribal / service-unit reads → `DDR GETS ENTRY DATA` / `DDR LISTER` /
>   `DDR VALIDATOR` over #9000001, TRIBE #9999999.03, SERVICE UNIT #9999999.22
>   (`RpmsRpc::Tribal`)
> - visit create → `BEHOENCX FETCH` with its CREATE flag
>   (`RpmsRpc::Encounter.create`; `GETVISIT^BEHOENCX` is a pure fetch)
>
> Replacement response layouts derive from M source and the live DD; rows without
> live captures are marked pending-capture at their mappings.

## See also

- [ADR 0001 — Scope and no Rails coupling](adr/0001-scope-and-no-rails-coupling.md)
- [ADR 0002 — Verified routine policy](adr/0002-verified-routine-policy.md)
- FOIA-RPMS XWBTCPM.m — XWB/CIA wire protocol
- FOIA-RPMS BMXMON.m, BMXMBRK.m — BMX wire protocol
- FOIA-RPMS XUSRB.m, XUSRB1.m — signon and cipher
