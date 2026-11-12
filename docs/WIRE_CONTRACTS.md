# Wire contracts: field-level return shapes, captured and gated

Status: first slice (issue #189). Extends the conformance pipeline
(docs/conformance/SPEC.md) from *"is the RPC registered / what return TYPE
does it declare"* down to the **field-level layout of an actual return**.

## The failure class this closes

TDD is robust for self-contained logic and systematically blind at the
external boundary: a mock's wire shape mirrors its author's belief, so a
mapping authored from belief and a test fed by a belief-mirroring mock agree
with each other while proving nothing about the real system. MockClient makes
this structural — it *formats seeds through the mapping under test*, so a
wrong mapping produces mocks wrong in exactly the same way, and everything
stays green.

The canonical example: **ORQQVI VITALS** shipped declaring
`TYPE^VALUE^UNITS^DATE` with green tests. The real wire is
`MEASUREMENT_IEN^TYPE^DATETIME^value` (VITALS^ORQQVI: ORQQVI.m:4-24 — there
is no units piece on that wire at all). Same session, same class: the
BHDPTRPC phantom RPC family, the DDR HRN pre-check reply grammar, and the
divergences this gate caught on its first run (below). All were caught only
by adversarial source reading — this gate makes the catch mechanical.

## The mechanism (capture → committed fixture → CI gate)

Same shape as the conformance pipeline, one level deeper:

1. **Capture** (`rake wire:capture`, human/agent step — like
   `conformance:ingest`): for the curated list in
   `RpmsRpc::WireCapture::CATALOG` (lib/rpms_rpc/wire_capture.rb), drive the
   real client (`RpmsRpc::CiaClient`) against a rung **we own** and write one
   provenance-stamped fixture per catalog entry to `test/fixtures/wire_captures/`
   (named by the RPC slug, or by the entry's own `fixture:` name when several
   entries share an RPC):
   the verbatim raw reply, its sha256, the inputs, the release tag, capture
   UTC, and the cited position→semantics annotation. Read-only behavioral
   calls with synthetic inputs only — never a customer instance.
   `rake wire:capture` never calls a write RPC (the conformance SPEC's
   non-negotiable applies to this read catalog verbatim). Scheduling writes
   are a separate capture, `rake wire:capture_writes`, gated below.
   One catalog entry is the single exception to "read-only": BEHOENCX
   CHKVISIT is captured live although it can file a Kernel alert (the
   NOEMC path, BEHOXQPC.m:37-41 into SEND 64-74, which calls ENTRY^XQALGUI)
   when a visit has a note but no E&M code. That is accepted because the
   capture runs only on a disposable pinned build, the alert would land in
   ALERT file #8992 there, and seed visit 1 has no note, so no alert is
   filed. Any change to the seed visit must re-check that before the next
   capture.

   ```sh
   bundle exec rake wire:capture BROKER_HOST=127.0.0.1 BROKER_PORT=<port> RELEASE=bcer-9.0-ydb
   bundle exec rake wire:capture CONTAINER=rpms-ydb-9.0 RELEASE=bcer-9.0-ydb
   # without CONTAINER= or BROKER_HOST=, only routine-cite fixtures are (re)written
   # WIRE_FIXTURES_DIR=<dir> writes the fixtures there instead (a scratch capture)
   # ONLY="RPC NAME" (or a fixture name) limits the run; CITE_ONLY="RPC A,fixture-b"
   # forces routine-cite output for live entries (e.g. broker unavailable).
   # CITE_ONLY matches a fixture name, or an RPC name only for the entry whose
   # fixture is the RPC slug. A token matching no live entry aborts before any call.
   # rake wire:compare reports one row per fixture.
   ```

   Scheduling writes are not part of that command. See [Write captures](#write-captures).

   Re-run when a rung changes (new release tag), like re-ingesting a
   fingerprint. With `BROKER_HOST=` (host mode) the driver,
   `bin/wire_capture_driver.rb`, runs on this machine's Ruby against the
   broker over the network; a release image carries no Ruby, so this is the
   mode that works on a release (rpms-ops#975, whose `make fresh-up` /
   `make fresh-capture` start a fresh container of a release and capture from
   it into a scratch directory). With `CONTAINER=` the task stages `lib/` and
   the driver into a container that has a Ruby and runs it there. Either way
   it refuses to write any fixture that fails provenance validation.

2. **Contract test** (`test/rpms_rpc/wire_contract_test.rb`, the always-on
   CI gate — like `conformance:probe`): runs against **committed fixtures
   only**, no live container. For every mapping with a capture it asserts
   the mapping's declared layout is consistent with the real return:

   - the attribute a mapping declares at position N is among the cited
     semantics of the piece the wire actually carries there
     (`:recorded_date` on a piece the routine builds as *date/time taken*
     passes; `:type` on the *measurement ien* piece fails);
   - a declared position beyond the captured/cited layout fails;
   - typed fields are validated against the live raw pieces themselves — a
     `:fileman_date` field whose captured piece is `120/80` fails no matter
     what the annotation says;
   - reply *kind* must match (a scalar mapping against a multi-field wire
     fails).

   CI runs it automatically: `rake test` globs `test/**/*_test.rb`, so the
   gate is in every push/PR build with no workflow change.

## Provenance rules (what a fixture must prove)

**A wire fixture without live-capture, no-data or routine-cite provenance
is rejected** — `WireCapture::Fixture` raises on load, in the capture task
and in CI both. Concretely:

- `source: live-capture` — `raw_return` is the verbatim broker reply
  (including the `{CIA}` sequence-echo/ack framing; parsing strips framing
  at read time so captured bytes are never edited), sealed by `sha256`,
  stamped with `release_tag` + `captured_at`. An edited raw fails the sha
  check and the fixture is rejected. It must also carry **at least one data
  row**: a reply that is only protocol framing, an error row, or a no-data
  sentinel proves the RPC answered and nothing about its field layout, and
  the one check that reads real bytes (`raw_type_violations`) would iterate
  an empty list and pass. Absence of data is never verification.
- `source: no-data` — a real call that came back empty (nothing seeded for
  that patient on the rung). The bytes and their `sha256` are kept as a
  record of what the box actually said, but the `pieces:` block is a source
  cite, not evidence, and the mapping counts as **uncovered**. Re-run the
  capture against a seeded box to promote it to `live-capture`. Declaring
  `live-capture` on an empty reply, or `no-data` on a reply that has data
  rows, is rejected either way.
- `source: routine-cite` — for RPCs that `rake wire:capture` does not call
  (a write RPC, which that task never calls; an RPC that faults the rung, like
  BEHOVM2 VUNITS on bcer-9.0-ydb). The shape is cited to the M routine
  serving the RPC in the release corpus
  (rpms-ops/data/standup/bcer-9.0-ydb/r/, file:line). A routine-cite
  fixture must **not** claim a `raw_return` (an illustrative row goes in
  `example_return`, which is never treated as evidence). Scheduling writes
  are not routine-cited stand-ins: `rake wire:capture_writes` captures them
  under the gates in [Write captures](#write-captures), and a write reply
  still is not proof.
- `kind: lines` covers mappings declared with `line_field` — one field per
  LINE of the reply, not per caret piece (19 registered mappings, including
  the sign-on / user-info reads). The contract checks these on line number
  and type-checks each captured line. Classification is automatic: a mapping
  with any `line_field` is `lines`, so a line-based mapping can no longer be
  gated as `fields`, which would have compared line numbers against caret
  positions — the wrong axis, and silently, since both are small integers.
- Every fixture — all kinds — must carry a `cite`: piece semantics always
  trace to the routine that builds the return, even when the bytes are live.
- Synthetic data only. Captures run against build-time test patients
  (DEMOPATIENT-style) on rungs we own; nothing identifying a partner, tribe,
  or real person may enter a fixture (public repo — see the workspace data
  hygiene rules).

## Adding an RPC to the gate

1. Read the M routine that serves the RPC (corpus at
   rpms-ops/data/standup/<release>/r/) and write down the position→meaning
   layout **with file:line cites**.
2. Add a `CatalogEntry` to `RpmsRpc::WireCapture::CATALOG`: RPC name, the
   mapping that parses it, reply kind, capture inputs (synthetic), the cite,
   and the piece annotations. `rake wire:capture` selects `mode: :live` only,
   so a write RPC does not belong in this catalog. A scheduling write belongs
   in `WRITE_CATALOG` (`mode: :write_live`) and is captured only by
   `rake wire:capture_writes`.
3. Run `rake wire:capture CONTAINER=<rung>` and commit the fixture.
4. The contract test picks the fixture up automatically. If the existing
   mapping diverges from the captured truth, the gate goes red — fix the
   mapping in its own reviewed change, or (when the fix belongs to another
   in-flight PR) pin the exact violating positions in `KNOWN_DIVERGENCES`
   in test/rpms_rpc/wire_contract_test.rb with the evidence in a comment;
   the gate then enforces that the divergence stays *exactly* that until the
   fix lands, and fails when it changes in either direction.

## What the gate caught on its first run

Committed captures from bcer-9.0-ydb (2026-09-02), first pass over ten RPCs:

- **`:problem_list` (ORQQPL LIST)** — declares
  `IEN^STATUS^DESCRIPTION^ICD^ONSET^RECORDED^PROVIDER_DUZ`; the wire is
  `IEN^NARRATIVE^STATUS^ICD^ONSET^LAST-MODIFIED^SC^...` (LIST^ORQQPL:
  ORQQPL.m:3-18 over LIST^GMPLUTL3: GMPLUTL3.m:76-99). Status/description
  swapped; position 5 is date-last-modified; position 6 carries the
  service-connected flag — no provider DUZ exists on this wire.
- **`:patient_id_info` (ORWPT ID INFO)** — position 3 is the VETERAN flag,
  not `:race_code` (the live `"N"` had been read as a race code), and
  position 5 is the current ward location, not `:site_ien` (IDINFO^ORWPT:
  ORWPT.m:6-11).

Both are pinned in `KNOWN_DIVERGENCES` — mapping fixes belong in their own
reviewed PRs; the capture side never edits a mapping to make itself pass.

## Write captures

`rake wire:capture_writes` captures the four scheduling writes (BSDX ADD NEW
APPOINTMENT, BSDX CHECKIN APPOINTMENT, BSDX CANCEL APPOINTMENT, BSDX NOSHOW).
They are captured only against a disposable rung we own: `LIVE_DISPOSABLE=1`,
a loopback `BROKER_HOST` (`127.0.0.1`, `localhost`, or `::1`), and `RELEASE`
set to a non-blank release tag. Never a customer instance. The task aborts
before it loads the driver or opens a socket when those guards fail, when
`RELEASE` is blank, or when `RPMS_ACCESS` is not a synthetic persona
(`SYS123` or `PROV123`; the default is `SYS123`).

A write's reply is not proof. The fixture's `read_back` is DDR GETS ENTRY
DATA taken immediately after the call: the appointment (`#9002018.4`) and
the patient appointment (`#2.98`). Check-in also reads the clinic appointment
on HOSPITAL LOCATION (`#44.003`, fields `.01`, `309`, and `302`). The driver
finds that sub-entry with DDR LISTER and records only the GETS call.

Check-in, cancel, and no-show issue those same GETS calls again immediately
before the write and store them as `read_before`. An effect counts only when
it was not already true on that prior read.

`source` is labelled from the write's own bytes
(`live-capture` when there is a data row, `no-data` when there is not). An
empty cancel reply is `no-data` and proves nothing by itself. A broker error
reply, or a write the API reports as refused, is not written; the previous
fixture stays. If any of the four captures is skipped, the task exits
non-zero after writing the ones that succeeded.

The ADD fixture's `persona_probe` is PROV123's booking reply. It is kept
only when that reply is a refusal: `WireCapture.error_reply?` is false, and
the first data row maps through `:scheduling_add_appointment` to an
appointment id of 0 or less with a non-empty error. A probe
`Scheduling.add_appointment` accepts is a step error on the ADD capture,
and that probe stays off the fixture.

These RPCs live in `RpmsRpc::WireCapture::WRITE_CATALOG` with
`mode: :write_live`. They are not `CATALOG` entries. `mode: :write_live` is
not `mode: :live`, so `rake wire:capture` still never calls a write RPC.

```sh
LIVE_DISPOSABLE=1 BROKER_HOST=127.0.0.1 BROKER_PORT=<port> \
  RPMS_ACCESS=SYS123 RPMS_VERIFY=<synthetic> RELEASE=<release> \
  bundle exec rake wire:capture_writes
```

The driver is `bin/wire_capture_writes_driver.rb`. Credentials reach it
through the environment, never on argv. The verify code is never written to
a fixture, the driver JSON, or a log line. `PROV123` signs on through the
client's development fallback (`VISTA_RPC_ENV=development`); the driver does
not set that verify code. `WIRE_FIXTURES_DIR` redirects the fixtures, same
as `rake wire:capture`. `RELEASE` is required and stamps `release_tag`.

## Honest limits

- A fixture proves the wire shape **on the release it was captured from**
  (`release_tag`). Cross-release drift is the conformance ladder's problem;
  re-capture per rung as references land.
- Empty live captures (a test patient with no vitals/visits yet) evidence
  the empty-return form and the reply kind; position semantics on such
  fixtures rest on the routine cite until a populated capture replaces them.
- The gate covers mappings with committed fixtures — currently the curated
  ten. Everything else is exactly as unguarded as before; extend the catalog
  as mappings are touched.
