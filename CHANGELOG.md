# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Composed patient registration replaces the last BHDPTRPC placeholder
dispatch. The CIA reply grammar, `VAFC VOA ADD PATIENT`, `DDR FILER`/`GETS`,
and the identity-guard read are now LIVE-VERIFIED end to end against
`rpms-ydb-9.0` (contracts: rpms-ops `docs/REGISTRATION_RPC_CONTRACTS.md`).

### Added

- `RpmsRpc::Registration` — patient registration composed from stock-VistA
  RPCs: `VAFC VOA ADD PATIENT` (PATIENT #2 half, returns the DFN) → an
  **identity guard** (`ORWPT ID INFO`, aborts a wrong-patient ICN collision
  before any write) → `DDR LOCK/UNLOCK NODE` + `DDR GETS ENTRY DATA`
  (idempotent-re-run existence probe) + two `DDR FILER` passes (the #9000001
  stub `.01`/`.02` DATE ESTABLISHED/`.11` ESTABLISHING USER at the DINUM
  IEN = DFN — AUPNLK2.m:55-58, then the HRN 41-multiple entry and
  tribe/community/classification/eligibility fields). Error taxonomy:
  `:voa_rejected` / `:identity_mismatch` / `:lock_failed` / `:filer_rejected`
  (message carries the M-side text). Documents the KNOWN DIVERGENCES from
  AG-native registration: no HRN-uniqueness enforcement (proven not
  FileMan-enforced — field .02 transform is format-only, its "D" xref a plain
  SET index; uniqueness is AG-procedural), no `^XTMP("AGHL7")` HL7 staging,
  FileMan-transform validation only.
- `RpmsRpc::DdrFileman` — wrapper for the FileMan Delphi Components RPC
  family (`DDR FILER` / `DDR LISTER` / `DDR LOCK/UNLOCK NODE` /
  `DDR GETS ENTRY DATA` / `DDR VALIDATOR`) with public request builders
  and reply-grammar parsers. `lock` is tri-state (`true`/`false`/`nil`) so
  callers separate contention from an unreachable broker.
- `MockClient#seed_sequence` — FIFO seeding of successive text-blob replies
  for one RPC+key, making stateful multi-pass flows (FILER stub-then-completion,
  partial-failure-then-retry) testable.
- `CiaClient` list params: `Hash` params encode as named-subscript
  NAME/SUBSCRIPT/VALUE triples (string subscripts M-quoted, numeric bare
  — the raw-splice contract of DOACTION^CIANBLIS), `Array` params as
  1-based numeric subscripts; matches `XwbClient`'s public param
  convention.

### Fixed

- **CIA reply framing (blocker).** `CiaClient#call_rpc` now DEFRAMES the
  broker reply: it strips the 1-byte sequence echo and `\x00` ack the broker
  prepends, and normalizes the wire's **bare-CR** line delimiters to LF.
  Previously `printable` flattened `\r`/`\n`/`\x00` all to spaces, so every
  multi-line `DDR` reply collapsed to one line and `session_params` (splitting
  on CRLF/LF, never bare CR) always missed the session UID — leaving
  `session_uid`/`DUZ` nil and cascading the client into a UID-1 reconnect.
  Verified live: with the fix `session_uid` is captured and the DDR reply
  grammar parses. `call_rpc_raw` stays byte-exact (its contract is the
  unmodified reply). (rpms-ydb-9.0, 2026-09-02.)
- `DdrFileman` DIERR extraction now locates the human-readable TEXT lines by
  the `ERROR^DDR3` header's txtcnt/paramcount (DDR3.m:66-79) instead of
  dropping every `^`-containing line — a DIERR TEXT line that itself contains
  a caret (e.g. an echoed bad value) is no longer silently lost.
- `CiaClient#authenticate` requests session UID `0` on first sign-on (was
  hard-coded `"1"`), so `AUTH^CIANBRPC` allocates a fresh session
  (`CIANBRPC.m:58-59`) instead of a failing reconnect. (Carried from #186;
  now proven together with the framing fix.)

### Changed

- `Patient.register` now delegates to `Registration.register`; failures
  return `{ success: false, error: Symbol, message: String }` instead of
  `error: String`. Public docs hoist the FileMan-INTERNAL value requirement
  and the ONC scoping statement (uncertified/additive; demographics is
  certified via AG/BPRM, not this path).

### Removed

- The recreated HRN "D"-xref uniqueness **pre-check** (`DDR LISTER`) — it was
  unimplementable (a no-FIELDS LISTER returns bare-IEN rows, no HRN piece) and
  FileMan does not enforce HRN uniqueness anyway; uniqueness is an AG-procedural
  invariant unreachable via DDR. With it went the fabricated `:hrn_taken` and
  `:duplicate_identity` error classes (the latter keyed off VOA `-1` text; a
  real duplicate ICN is not a VOA error) and the `extra_fields` escape hatch
  (it bypassed the declared schema — use `RpmsRpc::DdrFileman` for raw writes).
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
