# Registration safety (#407)

`Patient.register` / `Registration.register` now check the AG patient
candidates before `AGG ADD NEW PATIENT` can file anything.

The lookup runs under `AGGRPC`, across divisions and including inactive charts.
It sends the same name pieces and normalized DOB as the add, using the
`AGGPTLNM`, `AGGPTFNM`, `AGGPTMNM`, `AGGPTSFX`, `AGGPTDOB` pairs separated by
`$C(28)`. `FND^AGGPTLKP`'s structured branch searches by **name OR DOB** and
unions the results (AGGPTLKP.m:33–45, LST2). Both lookup and add use the server's
`XLFNAME1` name formatter. Empty middle/suffix pieces are sent explicitly to
the lookup so a previous call's locals cannot supply them.

Every returned candidate requires review. This includes same-name/different-DOB
and same-DOB/different-name candidates. The lookup does not return sex; Ruby
must not invent a sex comparison or treat a DOB difference as proof that
`ADD^AGGPTADD` cannot resolve a same-name chart. This conservative policy can
require review for different people sharing a DOB.

```ruby
result = RpmsRpc::Patient.register(attrs)
# { success: false, error: :duplicate_identity, candidate_dfns: [42, 43],
#   message: "matching patient candidates require explicit override" }

# After the caller reviews those candidates:
result = RpmsRpc::Patient.register(attrs.merge(allow_duplicate: true))
```

Only literal `true` overrides candidates, and the lookup still runs. Missing,
malformed or failed lookup replies return `:identity_unverifiable`, even with
an override. A complete typed header with no rows is the evidence for an empty
result. Guard messages contain field names, never demographic values or raw
broker errors; candidate DFNs are returned separately.

A missing last name (including a leading comma), first name, DOB or sex refuses
before lookup. Invalid DOB or sex refuses too. Existing malformed-name argument
errors still raise `ArgumentError`. Dates are parsed and sent as MM/DD/YYYY to
both calls. `1/2/90` means January 2, 1990; Ruby's `%y` boundary is 69–99 for
1969–1999 and 00–68 for 2000–2068. Prefer four-digit years. A parameter delimiter
in any AG value raises before lookup, preventing another field from replacing
the checked name in the add payload.

## How this addresses the issue on current main

PR #409 removed the VOA + DDR registration path and the `Agg.available?`
dispatch in version 0.4.0. The ICN overwrite path described by #407 therefore
cannot run, and a failed availability probe cannot select it. This change does
not restore that path or its unused chart-comparison implementation. A refused
AG lookup results in an explicit failure and no write.

The remaining AG path has the required pre-add lookup and explicit override.
`DdrFileman.lock` also preserves three states: `true` acquired, `false` refused,
`nil` unanswered. `Registration.update` now uses AG locking after #430 (which removed DDR
patient edits); its unchanged retryable `:lock_failed` behavior for a refused
or unanswered AG lock is covered by the upstream update suite. Neither AG
registration nor AG updates use the DDR lock helper.

## Evidence and limits

- The focused tests were run against unchanged main first: 38 failures and
  three errors in 42 tests, exposing unguarded writes and absent lookups.
- The full offline suite passed: 1,700 tests, 8,150 assertions, no failures,
  errors or skips (Ruby 3.4.9).
- Fourteen deliberate mutations were caught: omit the duplicate guard; accept
  a truthy override; override a failed lookup; omit identity validation;
  hardcode the field-list message; omit each required field independently;
  omit DOB from lookup; accept a missing header; accept malformed rows;
  collapse unanswered locks to false; permit parameter injection.
- `test/live/registration_duplicate_live_test.rb` passed over CIA on a fresh
  disposable container of `ghcr.io/lakeraven/rpms-ydb:local-arm64-46dd047`, as
  both SYS123 and PROV123, with the default HRN flow. It registers a synthetic
  identity, opens a fresh session, repeats registration, and checks that the
  lookup still finds exactly one DFN. Each run: one test, six assertions. The test reads `XUPROGMODE` from
  the server: SYS123 held it (1), PROV123 did not (0).
  This is evidence on that local image, not a claim about every release or
  the repository's different pinned image. Discard the container afterwards;
  there is no supported patient-delete RPC.

Reproduce the live test with the usual live-harness credentials and
`BROKER_HOST=127.0.0.1`, the disposable container's `BROKER_PORT`,
`LIVE_DISPOSABLE=1`, `PERSONA` and `LIVE_BUILD`:

```sh
bundle exec ruby -Ilib:test test/live/registration_duplicate_live_test.rb
```

This is a preflight, not an atomic duplicate constraint. Concurrent sessions
can both observe no candidates before either adds. The server also applies its
facility deceased-patient visibility setting to the lookup. An override still
invokes stock AG's add routine and does not prove it will create a new DFN.
Eliminating those limitations requires server-side policy/transaction work;
this client change neither repairs existing duplicates nor proves away #292's
source-reported name-resolution risk.

References: [#407](https://github.com/lakeraven/rpms-rpc/issues/407),
[#409](https://github.com/lakeraven/rpms-rpc/pull/409),
[#291 review](https://github.com/lakeraven/rpms-rpc/pull/291#issuecomment-5881497707).
