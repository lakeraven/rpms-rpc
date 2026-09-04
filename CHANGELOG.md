# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Composed patient registration replaces the last BHDPTRPC placeholder
dispatch. Live round-trip verification is gated on the rpms-ops evidence
run (contracts: rpms-ops `docs/REGISTRATION_RPC_CONTRACTS.md`).

### Added

- `RpmsRpc::Measurement.find` — one V MEASUREMENT by IEN via
  `DDR GETS ENTRY DATA` on #9000010.01 (field numbers cited from corpus
  readers: .02 patient DFN — APCDBMI.m:20; .03 visit — APCDBMI.m:22 /
  BHSMEA.m:87; .04/1201/2 — the exact set BTIUPCC4.m:19 reads; .01 type
  whose external form is the abbreviation — BEHOVM2.m:65-66), decorated
  with service category / capture mode / units like `.for_visit`. Returns
  `:patient_dfn` so id-addressed FHIR lookups (Provenance target search)
  can resolve the patient from a measurement IEN alone.
- `RpmsRpc::Measurement.newest_by_type` — the patient's newest
  measurement per vital type (optional FileMan date range) via
  `ORQQVI VITALS`, each row decorated per measurement via the `.find`
  DDR read + `BEHOENCX GETVISIT` + `BEHOVM2 VUNITS` (memoized).
  Decoration degrades to nil fields (`capture_mode: :unknown`,
  `entered_in_error: nil`, `units: nil`) — unknown is reported as
  unknown, never fabricated. This replaces a briefly-added `.history`
  method whose "full patient history" claim was false: the registered
  `ORQQVI VITALS` dispatches to FASTVIT^ORQQVI (newest-per-type only).
  No registered RPC currently provides a verifiable full V MEASUREMENT
  history (see the `:vitals_for_date_range` mapping notes), so the gem
  does not pretend to one.
- Rows from the `Measurement` reads now carry `:date_source` labeling the
  clinical-date provenance — `:event` (#9000010.01 field 1201, the taken
  time the writer files — BEHOENPC.m:275,286), `:visit` (1201 empty →
  the visit's own date, the canonical readers' fallback — BPXRMPX.m:60-64,
  BGOVMSR.m:29), or `:entered` (only .07 TIME ENTERED available — an
  administrative save timestamp (BEHOENPC.m:274,287; BPXRMPX.m:70),
  surfaced labeled instead of silently substituted for clinical time).

- `RpmsRpc::Measurement.for_visit` / `.latest` — measurement reads that
  carry FHIR-Provenance signals, composed entirely from existing
  registered RPCs (no new M): `BGOVMSR GET` / `BGOVMSR LAST` (rows with
  the visit IEN — GET/LAST^BGOVMSR), `BEHOENCX GETVISIT` (the visit's
  SERVICE CATEGORY, #9000010 field .07 — GETVISIT^BEHOENCX),
  `DDR GETS ENTRY DATA` (#9000010.01 field 2 ENTERED IN ERROR — the flag
  `EIE^BEHOVM2` stores and `BLDXRF^BEHOVM` filters on — plus the internal
  1201/.07 date/time), and `BEHOVM2 VUNITS` (display units for the raw
  US-unit stored value). Each row:
  `{ type:, value:, units:, date:, date_display:, measurement_ien:,
  visit_ien:, service_category:, capture_mode:, entered_in_error:, ... }`
  with `capture_mode` classifying the service category
  (A/H/I/S/O/R/D → `:office`, T/M/E/C → `:reported`, else `:unknown` —
  code set cited from PXRHS01.m:14-26 and APCDEIN.m:85). Note
  `BGOVMSR GET`/`LAST` do NOT filter entered-in-error rows (unlike the
  BEHOVM query path), which is why the explicit flag is part of the read.
- `RpmsRpc::Patient.contact` — patient telecom
  (`phone_home`/`phone_work`/`phone_cell`/`email`, PATIENT #2 fields
  .131/.132/.134/.133) via the registered generic FileMan read
  `DDR GETS ENTRY DATA`. The full corpus×registry sweep of
  `^DPT(*,.13)` readers found no registered purpose-built structured
  alternative: `BEHOPTCX PTINFO1` has exactly these fields but is not
  in the #8994 registry; `DGRR GET PATIENT SERVICES DATA` (XML) and
  `BQI MAIL MERGE LIST` / `VEN ASQ GET DATA` carry only subsets in
  awkward envelopes; nothing purpose-built serves the cellular phone.
- Mappings `:visit_measurements`, `:latest_measurements`, `:vital_units`;
  `:encounter_visit` now exposes `:service_category` (verified reply
  piece 3 — GETVISIT^BEHOENCX header), `:visit_id` (piece 5 is the visit
  id, not a ward) and `:locked`, keeping `:status`/`:ward` as legacy
  aliases. `DataMapper#format_one` supports aliased positions (an
  unseeded alias no longer blanks a seeded one).

- `RpmsRpc::Registration` — patient registration composed from verified
  stock-VistA RPCs: `VAFC VOA ADD PATIENT` (PATIENT #2 half, returns the
  DFN) then `DDR LOCK/UNLOCK NODE` + `DDR LISTER` (HRN "D"-xref
  uniqueness pre-check) + `DDR GETS ENTRY DATA` (idempotent-re-run
  existence probe) + two `DDR FILER` passes (the #9000001 stub at the
  DINUM IEN = DFN, then the HRN 41-multiple entry and
  tribe/community/classification/eligibility fields). Explicit error
  taxonomy: `:voa_rejected` / `:duplicate_identity` / `:lock_failed` /
  `:hrn_taken` / `:filer_rejected` (message carries the M-side text).
  Every wire shape cites its M routine (bcer-9.0-ydb corpus).
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

- `:problem_list` (`ORQQPL LIST`) declared a fabricated row shape —
  STATUS and DESCRIPTION swapped, and RECORDED_DATE / PROVIDER_DUZ
  invented at pieces 6-7. Verified wire (LIST^ORQQPL: ORQQPL.m:3-18,
  reshuffling the LIST^GMPLUTL3 row — GMPLUTL3.m:76-124) is
  `IEN^NARRATIVE^STATUS^ICD^ONSET^LAST MODIFIED^SC^SPEXP^TRANSCRIBED^PRIORITY^^DETAIL`
  with STATUS = #9000011 field .12 internal (`"A"`/`"I"`). Under the old
  mapping a real inactive row put the narrative text into `:status`, so
  downstream FHIR mappers defaulted the unrecognized value to "active".
  `Problem.for_patient` now also drops the `"^No problems found."`
  sentinel row (ORQQPL.m:17). `:problem_filter` (`BGOPROB GET CLASS`,
  still best-effort) is redeclared to match.
- `:vitals` (`ORQQVI VITALS`) — fixed TWICE, and the second fix is the
  lesson. The original mapping matched an invented `TYPE^VALUE^UNITS^DATE`
  shape. The first correction read a plausibly-named tag
  (VITALS^ORQQVI) and declared `IEN^TYPE^DATETIME^VALUE` — but the #8994
  registry dispatches "ORQQVI VITALS" to **FASTVIT^ORQQVI**
  (`.broker_dumps_8994_20260607.txt:565`), whose rows are
  `IEN^TYPE^VALUE^DATETIME` (header ORQQVI.m:66-67; rows ORQQVI.m:113/
  179) — value and date were swapped, and the RPC returns only the
  NEWEST value per type, not history. The shape the first fix declared
  belongs to a different RPC, "ORQQVI VITALS FOR DATE RANGE"
  (dump line 795), now declared as `:vitals_for_date_range` with its
  GMRV-#120.5-only limitation documented. Method: resolve the registry
  name→tag mapping FIRST, then read that exact tag's return
  construction — grepping a routine for a plausible tag finds the wrong
  entry point. `Vital.for_patient` documents newest-per-type semantics,
  takes an optional date range, and guards invalid DFNs; FASTVIT emits
  no sentinel (that belongs to VITALS^ORQQVI), but IEN-less rows are
  still dropped defensively. `:fileman_datetime` coercion now always
  yields a `Time` (midnight for date-only values) instead of sometimes
  `Time`, sometimes `Date`.
- `:medication_list` (`ORQQPS LIST`) declared a fabricated
  `IEN^DRUG_NAME^SIG^STATUS^LAST_FILL^REFILLS^PROVIDER` shape. Verified
  wire (registry dump line 576 → LIST^ORQQPS: ORQQPS.m:4-55, header
  ORQQPS.m:5) is `ID^NAME^STOP_DATE^ROUTE^SCHEDULE(or infusion
  rate)^REFILLS(outpatient only)` — no SIG/STATUS/PROVIDER pieces exist.
  `Medication.for_patient` drops the `"^No medications found."` sentinel
  (ORQQPS.m:53) and guards invalid DFNs.
- `DdrFileman.gets_entry` reports a reply with no parsed rows and no
  `[Data]` marker as an error (broker error strings like `-1^...` match
  neither), so `Measurement` EIE reads degrade to `nil`/unknown and
  `Patient.contact` returns `nil` instead of fabricating
  `entered_in_error: false` / "no telecom on file" from a failed read.
- `Problem.for_patient` / `Vital.for_patient` / `Medication.for_patient`
  short-circuit nil/blank/non-positive DFNs to `[]` without dispatching
  an RPC.
- `client.rb` requires `rpms_rpc/version` so a standalone
  `require "rpms_rpc/cia_client"` (how the release evidence drivers load
  the gem) keeps `RpmsRpc.sanitize_error`: without it every client error
  path raised `NoMethodError` instead of the real broker error (observed
  live against rpms-ydb-9.0).
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

### Removed

- The `BHDPTRPC REGISTER` placeholder mapping and its single-caret-param
  contract (`Patient.registration_param`) — the wire name never had a
  server implementation anywhere (docs/RPC_COVERAGE.md, "BHDPTRPC
  provenance").

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
