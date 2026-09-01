# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
