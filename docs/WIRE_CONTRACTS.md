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
   provenance-stamped fixture per RPC to `test/fixtures/wire_captures/`:
   the verbatim raw reply, its sha256, the inputs, the release tag, capture
   UTC, and the cited position→semantics annotation. Read-only behavioral
   calls with synthetic inputs only — never a customer instance, never a
   write RPC (the conformance SPEC's non-negotiable applies here verbatim).

   ```sh
   bundle exec rake wire:capture CONTAINER=rpms-ydb-9.0 RELEASE=bcer-9.0-ydb
   # without CONTAINER=, only routine-cite fixtures are (re)written
   # ONLY="RPC NAME" limits the run; CITE_ONLY="RPC A,RPC B" forces
   # routine-cite output for live entries (e.g. broker unavailable)
   ```

   Re-run when a rung changes (new release tag), like re-ingesting a
   fingerprint. The task stages `lib/` plus `bin/wire_capture_driver.rb`
   into the container (the rpms-ops evidence-script pattern) and refuses to
   write any fixture that fails provenance validation.

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

**A wire fixture without live-capture or routine-cite provenance is
rejected** — `WireCapture::Fixture` raises on load, in the capture task and
in CI both. Concretely:

- `source: live-capture` — `raw_return` is the verbatim broker reply
  (including the `{CIA}` sequence-echo/ack framing; parsing strips framing
  at read time so captured bytes are never edited), sealed by `sha256`,
  stamped with `release_tag` + `captured_at`. An edited raw fails the sha
  check and the fixture is rejected.
- `source: routine-cite` — for RPCs that cannot be behaviorally captured
  (write RPCs like VAFC VOA ADD PATIENT; RPCs that fault the rung, like
  BEHOVM2 VUNITS on bcer-9.0-ydb). The shape is cited to the M routine
  serving the RPC in the release corpus
  (rpms-ops/data/standup/bcer-9.0-ydb/r/, file:line). A routine-cite
  fixture must **not** claim a `raw_return` (an illustrative row goes in
  `example_return`, which is never treated as evidence).
- Every fixture — both kinds — must carry a `cite`: piece semantics always
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
   and the piece annotations. Write RPCs get `mode: :routine_cite`.
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
