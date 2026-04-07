# ADR 0001: Scope and no Rails coupling

**Status:** Accepted
**Date:** 2026-04-06

## Context

`rpms-rpc` is a pure Ruby gem providing wire-level access to VistA/RPMS RPC
brokers via the CIA/XWB and BMX protocols. It is consumed by `lakeraven-ehr`
(a Rails engine) and may be consumed by other Ruby tools (workers, scripts,
non-Rails apps) in the future.

To stay reusable across consumers, the gem must not assume Rails is loaded.

## Decision

`rpms-rpc` has the following scope:

**In scope:**
- Pure Ruby RPC client classes (`RpmsRpc::CiaClient`, `RpmsRpc::BmxClient`)
- Wire protocol details: socket I/O, authentication, cipher exchange,
  parameter encoding, response parsing
- FileMan date format helpers
- PHI sanitization utility (used by both this gem and lakeraven-ehr)
- Plain Minitest tests (no Rails test helpers)

**Out of scope:**
- ActiveRecord, ActiveModel, ActionController, or any Rails dependency
- Domain wrappers (Patient, Practitioner, Encounter, etc.) — those live
  in lakeraven-ehr
- HTTP-based FHIR clients — that's a different layer
- Adapter contracts for Corvid — those live in private corvid-adapters
- PHI policy beyond sanitization — host concern

## Consequences

### Positive
- Reusable in any Ruby context: Rails apps, plain workers, scripts, REPL
- No transitive Rails dependency forced on consumers
- Tests run in plain `ruby -Ilib -Itest` without bundler boot
- Small gem surface — easy to audit, easy to maintain

### Negative
- `lib/phi_sanitizer.rb` must use `defined?(Rails)` guards if it wants to
  read `Rails.application.secret_key_base` — small awkwardness, accepted
- No ActiveSupport conveniences (`Time.current`, `String#presence`, etc.)
  unless we add `active_support` as a runtime dependency

### Alternatives considered
- **Bundle as part of lakeraven-ehr.** Rejected — couples the wire client
  to a Rails engine, prevents reuse in non-Rails contexts.
- **Add `activesupport` as a runtime dep.** Deferred — only add if a
  concrete need appears. Plain `Time.now` and `Date.today` are fine for
  the current scope.

## References
- ADR 0002: Verified routine policy
- `lakeraven-ehr` ADR 0004: depends on `rpms-rpc` for wire access
