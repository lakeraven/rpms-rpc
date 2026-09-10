# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed — AGG delegation never fired: the gate was asked in the wrong context (#225)

`Registration.register` gated delegation on `Agg.available?`, but **nothing on
that path ever bound the AGGRPC context**. RPC registration is OPTION-scoped —
`CANRUN` answers from the RPC multiple of the option bound right now
(`CIANBACT.m:148,155`) — and the AGG* RPCs are registered under AGGRPC alone
(`^DIC(19,13112,0)="AGGRPC^Patient Registration GUI^^B^…"`, with AGG ADD NEW
PATIENT / 8994 IEN 3374 at `^DIC(19,13112,"RPC","B",3374,20)`). They are absent
from both contexts this gem can be sitting on: **CIANB MAIN MENU** (#10976, what
CIA sign-on binds — no RPC multiple at all) and **OR CPRS GUI CHART** (#9649,
1004 RPCs, no 3374). So on any non-privileged session the gate was answered a
truthful 0, delegation silently never fired, and every registration fell back to
the VOA + DDR composition — skipping the AG capsule's HL7/MPI staging, the
`^AGPATCH` stamp and the edit-check rules that delegation exists to inherit. A
session holding `XUPROGMODE` cannot see this: the bypass (`CIANBACT.m:147`)
answers 1 either way.

- **New `RpmsRpc::ContextScope`** (`current_context` / `with_context`), included
  by `Client` and `MockClient`. `with_context` binds an option, runs the block
  and restores the caller's — no round trip when it is already bound, so
  nesting is free.
- **`RpmsRpc::Agg` binds its own context.** `available?`, `add_patient`,
  `update_patient` and `edit_check` all scope to `Agg::CONTEXT` ("AGGRPC")
  rather than telling callers to do it. Deliberate: leaving the bind to the
  caller is what made "not runnable HERE" indistinguishable from "AG not
  installed".
- **`CiaClient#create_context` now binds the CIA-native way — no round trip.**
  CIA carries the context as a **CTX field on the RPC frame**
  (`CIANBLIS.m:165,168` → `CIA("CTX")`; `CIANBACT.m:50,55`), so a switch is a
  client-side state change, not an `XWB CREATE CONTEXT` call — which, being
  `CRCONTXT^XWBSEC` (a non-`CIANB*` routine), would itself have to be
  registered to the option currently bound in order to change it. Sign-on binds
  `CIANB MAIN MENU` as the session AID (`CIANBRPC.m:22,27,62`), which the
  client now tracks. **Frames are byte-identical to before until something
  binds a context**; from the first bind onward every frame carries CTX,
  because ACTR persists the last CTX it saw and reuses it when a frame omits
  one — a restore that stopped naming the context would be a no-op.
- **Fail-safe, and now loud.** A context that will not bind, a "0" answer, an
  empty reply or an `RpcError` all return false and `warn` before composing
  VOA + DDR. Scoping a session with no declared context warns too: there is no
  "unbind", so it cannot be undone.

Live verification against a **non-privileged** session is still owed — #224.

### Corrected provenance — `CIANBRPC CANRUN` takes the RPC NAME (#225)

`Agg.available?` was reported as passing an RPC name to a gate that wants a
file-8994 IEN, which would have made AGG delegation fail closed for every
non-privileged session. **The M source says otherwise and no behavior
changed.** The registered entry is `"CIANBRPC CANRUN^CANRUN^CIANBRPC^1"`, so
the wire entry point is `CANRUN^CIANBRPC`, which resolves the IEN itself —
`S DATA=$$CANRUN^CIANBACT($$FIND1^DIC(8994,,"QX",RPC),CIA("CTX"))`
(`CIANBRPC.m:173-175`). Only the inner `CANRUN^CIANBACT` helper takes an IEN.
Passing the name is correct; passing an IEN would be the defect.

- `Agg::CANRUN_RPC`, the `Agg` wire-contract table and the `:agg_canrun`
  mapping comment now cite `CANRUN^CIANBRPC` (they said `CANRUN^CIANBACT`,
  the inner helper — the mislabel that produced the report).
- `Agg.available?` documentation now carries the full derivation, the two
  preconditions that legitimately answer 0 (the gate is per **context
  option**, and the context check at `CIANBACT.m:145` runs *before* the
  `XUPROGMODE` bypass at `:147`, so an un-contexted session is answered 0
  even for a programmer), the honest statement that a privileged session
  cannot prove the gate either way, and the fail-safe rationale for the
  VOA + DDR fallback.
- Regression tests pin the wire argument as the RPC **name** and prove a
  gate keyed on anything else does not satisfy the probe.

Live verification against a **non-privileged** session is still owed — that
is #224.

### Fixed (BGO write APIs rebound to the real writers — #217)

Four write APIs were bound to wrong-semantics RPCs; three silently faked
success and one filed wrong clinical data. All rebound against the FOIA M
source with the INP layouts each routine actually parses:

- `Problem.add/update` now call **BGOPROB SET** (SET^BGOPROB) with the
  "P"-line ARRAY contract; `Problem.delete` calls **BGOPROB DEL**. The old
  binding, BGOPROB1 EDPROB, is a *read* ("Get active problems") — writes
  were silently dropped while the API parsed a returned problem IEN as a
  "saved" IEN. **Breaking:** the problem hash is now the BGOPROB "P"-line
  contract (`PROB_FIELDS`: `:snomed_ct, :descriptive_ct, :description,
  :icd_code, :location_ien, :onset_date, :status, :problem_class,
  :problem_number, :priority`); `:location_ien` is required by the M side
  (-1049 without it). `EDIT_ACTIONS`/`EDPROB_FIELDS` removed.
- `Pov.add` → **BGOVPOV SET**, `HealthFactor.add` → **BGOVHF SET**,
  `ExamComponent.add` → **BGOVEXAM SET**, `Measurement.add` →
  **BGOVMSR SET**. The old shared binding BGOVUPD SET writes V
  UPDATE/REVIEWED (#9000010.54) — none of the four visit-data entries were
  ever filed. **Breaking:** `Measurement.add`'s `units:`/`qualifier:` are
  no longer transmitted (BGOVMSR SET has no such pieces — units are fixed
  by the measurement type); `Pov.add` modifier `:fraction` is now
  `:fracture`; `HealthFactor.add` gains `provider_duz:`/`quantity:`;
  `ExamComponent.add` gains `provider_duz:`.
- `ImmunizationRefusal.record` → **BGOREF SET** with refusal type
  "IMMUNIZATION" (the ^AUPNPREF personal-refusals writer). The old binding
  BGOREP SET writes *reproductive history* (^AUPNREP) — and BGOREF/BGOREP
  were swapped with the referral finding below. **Breaking:** signature is
  now `record(dfn, vaccine_ien, reason_ien:, narrative:, refusal_date:,
  provider_duz:)`; the invented `REASON_CODES` letter table is removed —
  reasons are REFUSAL REASON (#9999999.102) IENs, listed by the new
  `ImmunizationRefusal.reasons`. Success returns no IEN (the M API returns
  "" on success); broker silence is a failure, not a success.
- `Referral.create` is now honestly **`:not_implemented`**: BGOREF SET
  files refusals, and the real referral writer (BMC ADD REFERRAL =
  SETREFRL^BMCRPC2, 39 positional formals) cannot be faithfully driven
  from `create`'s small hash — use `Referral.add` with the full RCIS
  parameter list. `CREATE_FIELDS` removed.
- Mappings: `:problem_edit`, `:visit_data_save`, `:referral_create`,
  `:immunization_refusal_save` removed; `:problem_set`, `:problem_remove`,
  `:pov_set`, `:health_factor_set`, `:exam_set`, `:measurement_set`,
  `:refusal_set`, `:refusal_reasons` added.

### Fixed (clinical reads feeding FHIR — #218)

- `:problem_list` (ORQQPL LIST) columns corrected to the real wire
  (IEN^NARRATIVE^STATUS^ICD^ONSET^LASTMOD^SC^SPEXP — ORQQPL.m:14 over
  GMPLUTL3.m:120). **Breaking:** `:status`/`:description` positions were
  swapped; `:recorded_date` (really date-last-modified) is now
  `:last_modified`; `:provider_duz` (really the SC/NSC flag) is now
  `:service_connected`; `:special_exposure` added.
- `:vitals` (ORQQVI VITALS) columns corrected (IEN^TYPE^DATETIME^RATE —
  ORQQVI.m:6,23). **Breaking:** `:type` no longer carries the IEN (new
  `:ien` field), `:value` carries the rate (was the type name),
  `:recorded_date` the datetime (was the numeric value); `:units` removed —
  there is no units piece on this wire.
- `:medication_list` (ORQQPS LIST) columns corrected
  (ID^NAMEFORM^STOPDATE^ROUTE^SCHEDULE^REFILLS — ORQQPS.m:5,47).
  **Breaking:** `:sig`/`:status`/`:last_fill`/`:provider` removed (no such
  pieces exist); `:stop_date`/`:route`/`:schedule` added.
- `:allergy_list` (ORQQAL LIST) columns corrected
  (IEN^AGENT^SEVERITY^SIGNS — ORQQAL.m:8,14,18-21). **Breaking:**
  `:allergen` no longer carries the IEN (new `:ien` field), `:reaction`
  removed (it was the agent duplicated); `:signs` added (";"-joined
  signs/symptoms).
- `DataMapper` parse guard: broker error rows (`-N^message`) and no-data
  sentinel rows (`^message` — "^No problems found.", "^No Allergy
  Assessment", "^No Known Allergies", "^No vitals found.",
  "^No medications found.", …) never surface as data records from
  `parse_one`/`parse_many`. Mappings that legitimately model status/error
  replies opt out with `status_reply!` (`:voa_add_patient`,
  `:patient_lock`, `:immunization_exchange_status`).
- `Patient.find` returns `nil` for an unknown DFN instead of a phantom
  `{name: "-1"}` record (SELECT^ORWPT's `-1^^^^^Patient is unknown to
  CPRS.` — ORWPT.m:49).

### Added

- `RpmsRpc::Allergy.assessment(dfn)` — three-state allergy result
  `{ assessed:, nka:, allergies: [] }` so consumers (FHIR
  AllergyIntolerance) can distinguish assessed-no-known-allergies from
  not-assessed. `Allergy.for_patient` keeps the record-array shape and
  yields `[]` for both empty states.

The invented BHDPTRPC placeholder namespace is now fully removed
(issues #174/#184: zero hits across the 65,782-routine FOIA corpus, the
staging file-8994 fingerprint, and IHS public RPC docs), and patient
registration now delegates to the IHS AG package when it is present,
composing verified stock-VistA RPCs otherwise. Live round-trip
verification is gated on the rpms-ops evidence run (contracts: rpms-ops
`docs/REGISTRATION_RPC_CONTRACTS.md`).

### Added

- `RpmsRpc::Registration.update` / `Patient.update` — composed patient
  edit: `DDR FILER` (`FILE^DIE`, internal values) for PATIENT (#2) and
  IHS PATIENT (#9000001) fields under the same `^DPT(DFN)` lock
  `EDIT^VAFCPTED` takes. The VA edit routine itself has no `^XWB(8994)`
  registration on any observed target, so the registered generic filer
  is the edit path.
- `RpmsRpc::Encounter.create` — visit get-or-create over the registered
  `BEHOENCX FETCH` with its CREATE flag (`-1` always / `0` never / `1`
  if-not-found); creation descends to `GETVISIT^BSDAPI4`, the IHS PCC
  visit-creation API. `GETVISIT^BEHOENCX` is a pure fetch and never
  creates (rpms-ops `docs/REGISTRATION_RPC_CONTRACTS.md` §3). Reply
  layout is source-derived (`:encounter_get_or_create`); live capture
  pending.
- `RpmsRpc::Tribal.tribes` — tribe list via `DDR LISTER` over the TRIBE
  (#9999999.03) "B" index.

- `RpmsRpc::Agg` — the AG-package GUI registration RPC surface
  (`AGG ADD NEW PATIENT` = `ADD^AGGPTADD`, `AGG UPDATE PATIENT` =
  `UPD^AGGPTUPD`, `AGG PATIENT EDIT CHECK` = `CHK^AGGEDCHK`), context option
  `AGGRPC`. Request framing is P1 window name / P2 DFN / P3 `$C(28)`-delimited
  `NAME=VALUE` PARMS; the reply is a GLOBAL ARRAY (typed header row, then
  `$C(30)`-separated records, `$C(31)` end sentinel). `Agg.available?` gates
  delegation on real registry evidence — `CIANBRPC CANRUN "AGG ADD NEW
  PATIENT"` — which reports RPC presence WITHOUT executing the write RPC
  (rpms-rpc#209/#214). Wire layouts capture-verified live on bcer-9.0-ydb.
- `CiaClient#call_rpc_global_array` — reads a GLOBAL ARRAY (return type 4)
  reply to its `$C(31)` sentinel. The default read stops at the first EOD,
  which for AGG replies is the header's embedded `$C(30)` record separator
  (== the CIA EOD), truncating the data records.
- `RpmsRpc::Registration` delegation lineage — when `Agg.available?`,
  registration calls `AGG ADD NEW PATIENT` / `AGG UPDATE PATIENT`, inheriting
  the AG capsule's HL7/MPI staging, `^AGPATCH` register stamp and
  edit-check completeness rules instead of reimplementing them.
- `RpmsRpc::Registration` composition lineage (the lineage-portable floor for
  civilian/stock VistA with no AG package): `VAFC VOA ADD PATIENT` (PATIENT
  #2 half, returns the DFN) then `DDR LOCK/UNLOCK NODE` + `DDR GETS ENTRY
  DATA` (idempotent-re-run existence probe) + two `DDR FILER` passes (the
  #9000001 stub at the DINUM IEN = DFN, then the HRN 41-multiple entry and
  tribe/community/classification/eligibility fields). Explicit error
  taxonomy: `:voa_rejected` / `:duplicate_identity` / `:lock_failed` /
  `:filer_rejected` (composition), `:agg_rejected` / `:hrn_file_failed`
  (delegation). Every wire shape cites its M routine (bcer-9.0-ydb corpus).

### Changed

- HRN handling (rpms-rpc#214): the client no longer assigns or enforces
  HRNs. `Registration.hrn_mode` selects the policy. The greenfield default
  `:derive_from_dfn` sets **HRN := DFN** — FileMan's IEN allocation is the
  server-side atomic assigner, so the HRN is unique by construction with no
  client logic and no race. The legacy `:clerk_supplied` mode files the
  caller-supplied HRN as a plain passthrough. **The client-side HRN "D"-xref
  uniqueness pre-check (`DDR LISTER`) has been removed** — no client-side HRN
  validation remains in either mode. A server-held claim sequence
  (`DDR LOCK` → all-holders D-xref walk → `DDR FILER` → unlock, in one broker
  session) is documented follow-up for the clerk-supplied mode (#214), not
  this change.
- `RpmsRpc::DdrFileman` — wrapper for the FileMan Delphi Components RPC
  family (`DDR FILER` / `DDR LISTER` / `DDR LOCK/UNLOCK NODE` /
  `DDR GETS ENTRY DATA` / `DDR VALIDATOR`) with public request builders
  and reply-grammar parsers.
- `CiaClient` list params: `Hash` params encode as named-subscript
  NAME/SUBSCRIPT/VALUE triples (string subscripts M-quoted, numeric bare
  — the raw-splice contract of DOACTION^CIANBLIS), `Array` params as
  1-based numeric subscripts; matches `XwbClient`'s public param
  convention.

### Fixed

- `CiaClient#authenticate` now requests session UID `0` on first sign-on
  (was hard-coded `"1"`). `AUTH^CIANBRPC` treats a non-zero UID as a
  reconnect to that session; on any box with an existing session #1 it
  failed "reconnection attempt for session #1 has failed. The session was
  authenticated for a different user.", bound no DUZ and no context, and
  every gated RPC then returned "Access denied for remote procedure." UID
  `0` makes the broker allocate a fresh session (`CIANBRPC.m:58-59`) whose
  UID the client now adopts and carries on later frames.

### Changed

- `Patient.register` now delegates to `Registration.register`; failures
  return `{ success: false, error: Symbol, message: String }` instead of
  `error: String`.
- `RpmsRpc::Tribal` reads now run on `DDR GETS ENTRY DATA` /
  `DDR VALIDATOR` over the real files (#9000001 tribal fields verified
  against the AG field maps and the live DD; TRIBE #9999999.03; SERVICE
  UNIT #9999999.22). Semantics narrowed to what the server actually
  offers: `enrollment`/`eligibility` project internal/external field
  pairs (the invented `:active`/`:eligible_for_ihs`/`:benefit_package`/
  `:region` keys are gone); `validate` is input-transform validation of
  the enrollment number (#9000001 field .07) — no server-side
  membership check exists; `service_unit`/`tribe_info` take table IENs
  instead of a DFN/code.

### Removed

- The entire `BHDPTRPC` placeholder namespace. Earlier: the `REGISTER`
  mapping and its single-caret-param contract
  (`Patient.registration_param`). Now: the remaining seven wire names
  and mappings — `TRIBAL`, `TRIBALVAL`, `TRIBELIST`, `TRIBALELG`, `SU`
  (`:tribal_enrollment`, `:tribal_validation`, `:tribe_info`,
  `:enrollment_eligibility`, `:service_unit` caret forms), `UPDATE`
  (`:patient_update`), and `NEWVISIT` (`:encounter_create`). The
  namespace was invented and never had a server implementation anywhere
  (docs/RPC_COVERAGE.md provenance notes; issues #174/#184).

## [0.2.0] — 2026-09-01

CIA client wire-behavior corrections (#178, #179, #180, #177). Public API
kept compatible.

### Added

- `RpmsRpc::Client::RpcTimeoutError` — raised when a single RPC's reply
  times out mid-call. Subclass of `TimeoutError` (and so
  `ConnectionError`), so existing rescue blocks keep working; the client
  closes the socket first (a `{CIA}` reply abandoned mid-read cannot be
  resynchronized), so callers reconnect and re-authenticate rather than
  retrying on a corrupted stream. (#178)
- `CiaClient#authenticate` populates `duz` at sign-on via the
  context-exempt `CIANBRPC GETVAR`, and captures the broker-assigned
  session UID for later calls. (#178)

### Fixed

- `CiaClient` sequence byte cycles 1–9 so the fixed-width `{CIA}` header
  survives ten or more exchanges on one connection. (#179)
- A failed CIA connect handshake closes the socket and resets to a
  defined disconnected state instead of leaking the open socket behind a
  retried connect. (#178)
- `ESignature` sends the verified TIU/ORWU wire shapes: the signature
  code crosses the wire XWB-encrypted, the signer rides the
  authenticated session DUZ (never the wire), `remove` dispatches
  `TIU DELETE RECORD`, and `action: :addend` raises `ArgumentError`
  rather than mis-signing. (#180)
- `DataMapper::Mapping#parse_many` no longer crashes on a bare String
  where a list was expected; a broker `-1^message` error string yields
  no rows instead of a bogus record parsed from the error text. (#177)

## [0.1.0] — 2026-04-07

Initial release. Pure Ruby RPC client extracted from `rpms_redux`.

### Added

- `RpmsRpc::Client` — abstract broker base class with connection
  lifecycle, XUS signon authentication, XWB cipher encryption
  (`xwb_encrypt` matching `$$ENCRYP^XUSRB1`), and socket helpers.
- `RpmsRpc::CiaClient` — XWB/CIA wire protocol on port 9100,
  per FOIA-RPMS XWBTCPM.m.
- `RpmsRpc::BmxClient` — BMX wire protocol on port 9200,
  per FOIA-RPMS BMXMON.m / BMXMBRK.m.
- `RpmsRpc::ParameterEncoder` — VistA `1{len}00f{value}\x04`
  parameter encoding with `ParameterTooLongError` at 999 bytes.
- `RpmsRpc::ResponseParser` — caret-delimited response parser
  with `RpcResult` struct and `pick_string` / `pick_value` /
  `piece` / `pipe_piece` / `pipe_param` helpers.
- `RpmsRpc::XmlResponseParser` — REXML-based parser for VistA
  RPC XML responses (`Gov.VA.Med.RPC.Response` and
  `VA.RPC.Error`).
- `RpmsRpc::FilemanDateParser` — bidirectional conversion between
  Ruby `Date`/`Time` and FileMan `YYYMMDD.HHMM` (year - 1700).
- `RpmsRpc::PhiSanitizer` — HIPAA-aligned scrubbing for log
  messages and hashes; HMAC-SHA256 identifier hashing with a
  12-character display prefix.
- ADR 0001 — Scope and no Rails coupling.
- ADR 0002 — Verified routine policy (every shipped RPC must
  be verified against MUMPS source in CIVITAS FOIA-RPMS).
- `docs/rpcs.md` — verified RPC audit trail.

### Notes

- Requires Ruby 3.4+.
- Runtime dependency: `rexml ~> 3.2` (default gem in 3.4+ but
  must be declared so Bundler puts it on the load path).
- No Rails dependency. No ActiveSupport on the load path.
- Test suite is hermetic — 116 tests, no sockets, no live RPMS.
