# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Composed patient registration replaces the last BHDPTRPC placeholder
dispatch. Live round-trip verification is gated on the rpms-ops evidence
run (contracts: rpms-ops `docs/REGISTRATION_RPC_CONTRACTS.md`).

### Added

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
