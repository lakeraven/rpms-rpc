# Registration identity checks (#407)

`Registration.register` composes RPC calls in Ruby. “Composition” is an API
implementation choice, not an RPC protocol feature or a server transaction.
There are two paths:

- **AG delegation:** `AGG LOOKUP PATIENTS` searches by normalized name, across
  divisions and including inactive charts. Ruby compares returned names and
  DOBs. Matching candidates return `:duplicate_identity` and `candidate_dfns`;
  no add or HRN update follows. Only `allow_duplicate: true` permits adding
  despite candidates. Incomplete candidate identity also requires review.
  A missing/malformed lookup reply refuses even with an override. The lookup
  RPC does not return sex, so candidate matching does not assume it does.
- **Composition:** `VAFC VOA ADD PATIENT` returns `1^DFN` for both a new patient
  and an existing ICN. That status alone does not prove identity. After VOA,
  `ORWPT ID INFO` must confirm the returned chart before any DDR lock or
  completion filing. Missing request last name, DOB or sex refuses before
  VOA. Unreadable/incomplete chart identity returns `:identity_unverifiable`;
  differing fields return `:identity_mismatch`. The comparison includes last
  name, the whole given-name portion (including middle/suffix when supplied),
  DOB, sex and SSN when supplied. Error messages name fields, never values.

Dates are parsed rather than compared as digit strings: `1/2/90` matches
January 2, 1990. Slash dates use month/day/year; two-digit years use Ruby's
`%y` interpretation (69–99 are 1969–1999, 00–68 are 2000–2068). Prefer explicit
four-digit years. Case and surrounding whitespace are normalized for names;
SSN hyphens and the M/MALE and F/FEMALE spellings do not cause disagreement.

Only an answered `false` from `Agg.available?` selects composition. RPC,
connection and context-bind errors propagate; silence returns `nil` without
selecting either write path. `DdrFileman.lock` preserves three outcomes:
`true` acquired, `false` refused, `nil` no answer. Registration returns `nil`
for a silent lock and `:lock_failed` for refusal. `Registration.update`
continues to report both as retryable `:lock_failed`.

```ruby
result = RpmsRpc::Patient.register(attrs)
# A duplicate result includes only candidate DFNs, not their demographics:
# { success: false, error: :duplicate_identity, candidate_dfns: [42],
#   message: "matching patient candidates require explicit override" }

# Only after the caller has reviewed those candidates:
result = RpmsRpc::Patient.register(attrs.merge(allow_duplicate: true))
```

No server reset or database migration is needed for these Ruby checks. Deploy
the updated gem and restart/reload applications that already loaded its code.
Reconnects or server restarts do not fix the old identity assumptions. The
separate AG limitation involving locals left in a long-lived server session
still calls for short broker sessions; see the `Agg` module documentation.

These checks do not repair existing duplicates or mistaken writes. They are
also not a transaction: VOA may have created the #2 record before read-back
fails, and AG lookup/add remain separate calls. Concurrent sessions can both
observe no candidate before adding. Eliminating that race needs a server-side
atomic duplicate policy. The source-reported AG name-lookup overwrite risk
is not disproved by this client patch; a preflight lookup cannot prove which
DFN a later `ADD^AGGPTADD` call will choose.

The regression suite exercises sequential registration twice with a stateful
mock (one add, followed by a duplicate refusal), wire framing, failed reads,
blank inputs, each compared field independently with exact messages, and lock
outcomes. It does not claim a live-broker reproduction. Before release, rerun
the duplicate scenario on a disposable baseline and verify that the intended
non-programmer context can call the lookup and read-back RPCs.

A local mutation pass confirmed that the focused suite fails for each of 15
changes: skipping chart verification; allowing missing identity; allowing an
unreadable chart; hardcoding all divergence field names; independently removing
each of the five field comparisons; skipping the AG duplicate guard; accepting
a truthy string override; ignoring candidate DOB; collapsing silent locks to
false; falling back on availability errors; and accepting a missing lookup
header. Mutations were applied one at a time and restored before final checks.

References: [issue #407](https://github.com/lakeraven/rpms-rpc/issues/407),
[prior review](https://github.com/lakeraven/rpms-rpc/pull/291#issuecomment-5881497707).
