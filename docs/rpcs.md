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

## Stock RPCs (#420)

Verified against the RPMS 9.0 YDB standup routines in rpms-ops
`data/standup/bcer-9.0-ydb/r/` (working tree `d37932d`; the pin commit
`e7923a47` does not store the routine files). Formal lists and context
options are the pinned inventory `bcer-9.0-20261012-e7923a4-ydb`
(`rpc_signatures.txt`, `rpc_reach.txt`, and `rpcs.json` parameters whose
source is `formals`). The unit fixtures for these wrappers are synthetic.
They are not live captures (ADR 0003).

| RPC name | Routine / Tag | Params | Return | Status |
|----------|---------------|--------|--------|--------|
| `AGG CHECK SENSITIVE PATIENT` | `CHK^AGGPTSEN` | DFN | Header `T00001SENSITIVE_INDICATOR`, one row 0/1/2 (`AGGPTSEN.m:7`, `:29-31`). The lookup audits through `SENS^DGSEC4` (`AGGPTSEN.m:30`). A non-canonical DFN raises before the call. Option `AGGRPC`. | verified |
| `AGG SEND SENSITIVE NOTIFY` | `NOT^AGGPTSEN` | DFN | Header `I00010RESULT`, one row from `NOTICE^DGSEC4` (`AGGPTSEN.m:43`, `:58-60`). The logged option is hardcoded in the routine. A non-canonical DFN raises before the call. Option `AGGRPC`. | verified |
| `AGG ERROR SCREEN` | `FND^AGGEDCHK` | ERRNUM (`""` lists every error) | Header `I00010ERROR_NUM^T00030WINDOW^T00008FIELD` then `$C(31)` (`AGGEDCHK.m:53-68`). `FER`'s data-row write is commented out (`AGGEDCHK.m:77`), so this pin returns the header only. A data row is still parsed when present. Option `AGGRPC`. | verified |
| `BGU MAILMAN MESSAGE` | `EN^BGUMAIL` | body, subject, Mailman group | `EN^BGUMAIL` sets `BGUARRAY(1)=1` and `BGUARRAY(2)="OK"` unconditionally after `D ^XMD` (`BGUMAIL.m:5-6`), so a nonexistent group still answers 1/OK. `success: true` means the routine ran, not that the group exists or that mail was delivered. Body lines split on `$C(175)` (`BGUMAIL.m:11`). Option `CIAV VUECENTRIC`. | verified |
| `BUSA LOG SECURITY AUDIT ENTRY` | `RPC^BUSARPC` | one pipe parameter `CAT\|ACTION\|CALL\|DESC\|DETAIL` | Header `I00001RESULT^T00250ERROR_MESSAGE` (`BUSARPC.m:304`, `:354`, `:363-367`). Missing `DUZ` is `0^DUZ is not defined` (`BUSARPC.m:359`). Option `BUSARPC`. | verified |
| `DG SENSITIVE RECORD ACCESS` | `PTSEC^DGSEC4` | DFN, DGMSG, DGOPT | Return type 2 (ARRAY): `RESULT(1)` is the first line and `RESULT(2+)` the following lines, no typed header (`DGSEC4.m:13-66`). The code is -1..4 in the #8994 text and also 5 for restricted access (`DGSEC4.m:43-46`, PATCH 1008). The call writes a DG SECURITY LOG entry (`DGSEC4.m:65`). Blank DFN is `-1` / `Required variable missing.` (`DGSEC4.m:36-38`) and is refused before the call. Any other non-canonical DFN is `-1` / `DFN must be a positive integer.` and sends nothing. Options: `OR CPRS GUI CHART`, `SCMC PCMM GUI WORKSTATION`, `PSB GUI CONTEXT - USER`, `ORRCMC DASHBOARD`. Those options can be bound from a CIAV VUECENTRIC session; the wrapper scopes `OR CPRS GUI CHART`. | verified |
| `DG SENSITIVE RECORD BULLETIN` | `NOTICE^DGSEC4` | DFN, DGOPT, ACTION | Single value `1` or `0` (`DGSEC4.m:67-83`). A non-canonical DFN raises before the call. Same four options as the access RPC. | verified |
| `ORWU DT` | `DT^ORWU` | X, `%DT` (default `TS`) | FileMan Y from `^%DT`, or `-1` (`ORWU.m:4-7`). `-1` is not a datetime. Option `CIAV VUECENTRIC`. | verified |
| `BSDX RESOURCES BY USER` | `RESUSR^BSDX01` | DUZ (`""` uses the signed-on user, `BSDX01.m:113`) | Same resource columns as `BSDX RESOURCES` (`BSDX01.m:100-112`). Option `BSDXRPC`. | verified |
| `BSDX CHECKIN APPOINTMENT` | `CHECKIN^BSDX25` | eleven client inputs after return formal `BSDXY`: APTID, CDT, CC, PRV, ROU, VCL, VFM, OG, CR, PCC, WHF | Recordset `ERRORID^MESSAGE`. Success row `0^` message (`BSDX25.m:12`, `:74`). FOIA `BSDX25.m:12` stops at `BSDXOG` (nine formals). Option `BSDXRPC`. | verified |
| `BEHOENCX GETVISIT` | `GETVISIT^BEHOENCX` | visit IEN | `LOC^VDT^SVC^PAT^VID^LOCKED` (`BEHOENCX.m:8-14`). Empty when the IEN is not a visit. Option `CIAV VUECENTRIC` (not `BSDXRPC`). Already used by `RpmsRpc::Encounter`; `Scheduling.checkin_visit` calls the same RPC. | verified |

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
> - registration → the AG package's `AGG ADD NEW PATIENT` / `AGG UPDATE PATIENT`
>   under `AGGRPC` (`RpmsRpc::Registration.register`). The `VAFC VOA ADD PATIENT`
>   + DDR composition that first replaced it was removed in #409: no RPMS
>   context serves `VAFC VOA ADD PATIENT` (rpms-ops#499, #674)
> - patient update → the AG package's `AGG UPDATE PATIENT`, one call per AG window, under
>   `AGG LOCK PATIENT` (`RpmsRpc::Registration.update`, #381). It replaced a `DDR FILER`
>   path: `EDIT^VAFCPTED` has no `^XWB(8994)` registration on any observed target
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
