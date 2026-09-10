# ADR 0003: Test-first RPC additions, with contract evidence as the input

**Status:** Accepted
**Date:** 2026-09-10
**Extends:** [ADR 0002 — Verified routine policy](0002-verified-routine-policy.md)

## Context

ADR 0002 requires every shipped RPC to be verified against real M source before
merge. It says nothing about *when* verification happens relative to writing the
code, and in practice it has been an end-of-work check.

That ordering fails at scale. rpms-rpc models 224 RPCs; the 9.0 YDB baseline
serves 5,557. Closing a family like `AMHG` (#227, 60 RPCs) or `AGG` (#228, 25)
by writing implementations and verifying afterwards reproduces exactly the
`rpms_redux` failure ADR 0002 was written to prevent — the assumed parameter
order or return shape is wrong, and nothing catches it until a live instance
does.

Two further gaps:

- **Verification had no mechanical input.** "Read the M source" is correct and
  unscalable. An author had to locate the routine, find the tag, and read the
  layout by hand, 95 times.
- **Nothing described the clinical behaviour** the RPCs exist to serve. A
  correct wire mapping can still model the wrong thing.

## Decision

### 1. Contract evidence comes first, and it is generated

Before any mapping is written, the RPC's contract is extracted from artifacts we
already capture — the #8994 registry and the M source that backs it:

```sh
# in rpms-ops
bin/rpc_contract_extract.rb --release <release> --routines <standup>/r \
  --names <rpc-list> --out data/observed/<release>/rpc_contracts.tsv
```

Each row carries the entry point (`VISITL^AMHGD`), the formal parameter list
(`RETVAL,AMHSTR`), the #8994 return type, the BMX typed header when the routine
builds one, the record/field separators in use, and a `routine.m:line` citation
for every claim.

This is evidence, not inference. It never guesses semantics.

### 2. The test is written before the mapping

Order is: **contract row → fixture → failing test → mapping → API module.**

- The fixture reproduces the layout the contract row records.
- The test fails first. A test written after a passing implementation tests the
  implementation, not the contract.
- The `DataMapper` field list and the API module cite the same `routine.m:line`
  the contract row does, matching the existing convention
  (`ORQQAL.m:12` in `stock_vista.rb`).

**Synthetic fixtures start the work; they do not finish it.** The first failing
test is written against a hand-built fixture derived from the contract row —
that is what makes the test writable before a live instance is reachable. It is
**not** sufficient for merge. Per ADR 0002 and #189, shipping requires the
mapping to be contract-tested against a **captured real return**, sanitized of
real patient data before it enters the repo. Both artifacts are synthetic *in
the repo*; only the second is evidence that the RPC actually behaves as the
source reads.

A mapping whose only evidence is a fixture the author wrote from the source is
**unverified**, and must be labelled so rather than merged as done.

### 3. Semantics are human judgement, stated in the API module

The extract deliberately stops at wire shape. Three-state sentinels, NKA-vs-
unassessed distinctions, and clinically-safe defaults are judgement and belong
in the API module with a comment explaining *why* that default is the safe one —
as `Allergy.assessment` does.

Where a safe default is not obvious, it is a question for a clinician, not a
choice for the author.

### 4. Behaviour is described where behaviour lives

TDD here proves the wire contract. It does not prove the feature is right.

Any RPC family added to serve a product capability gets a matching `.feature` in
**lakeraven-ehr**, written before the gateway work, describing the clinical
behaviour in domain language. rpms-rpc stays Rails-free (ADR 0001) and carries
no cucumber; the BDD tier lives in the consuming application.

A family added purely to close coverage, with no product capability behind it
yet, does not need a feature — but it also does not get merged as "done"; it is
modelled and marked unexercised.

### 5. Live verification remains the gate

The offline contract is a strong first draft. It is not proof the RPC behaves as
read. #189 (contract-tested against captured real returns, gated in CI) and #193
(sound **and** complete against a real instance) remain the merge gate. This ADR
changes when the work is *ordered*, not what must be true to ship.

## Consequences

**Cost.** Every addition now has a generation step before coding. For a single
RPC that is overhead. For a 60-RPC family it is the difference between a day of
extraction and a week of it.

**The extract can be wrong.** It reads the first label matching the registered
tag and scans a 60-line window for a typed header. A routine that builds its
header elsewhere yields an empty column — visible in the output, not silent. A
blank `typed_header` means *go read the routine*, never *there is no header*.

**Baseline-pinned.** Contract rows are extracted from one release. An RPC whose
shape changed between releases produces a row true of that baseline only; the
release is recorded in the output path for exactly this reason.

**We will model RPCs we cannot yet exercise.** 77 RPCs currently modelled are not
served by the 9.0 baseline. Test-first does not fix that, and those tests prove
wire shape against source rather than behaviour against an instance. They are
honest tests of a real contract, and they should not be mistaken for coverage.

## References

- [ADR 0001 — Scope and no Rails coupling](0001-scope-and-no-rails-coupling.md) — why the BDD tier cannot live in this gem
- [ADR 0002 — Verified routine policy](0002-verified-routine-policy.md) — the policy this ADR orders in time
- `rpms-ops bin/rpc_contract_extract.rb` — generates the contract rows
- `rpms-ops data/observed/<release>/rpc_contracts.tsv` — the current extract
- `rpms-ops data/observed/<release>/broker_8994.txt` — `NAME^TAG^ROUTINE^RETURN_TYPE`
- #189 — wire-shape mappings contract-tested against captured real returns, gated in CI
- #193 — every mapping verified sound **and** complete against a real instance
- #198 — AMH RPCs take a single pipe-delimited parameter (`YDB-E-ACTLSTTOOLONG`)
- #227 `AMHG`, #228 `AGG` — the first families ordered under this ADR
