# Conformance Probe Spec

Status: draft (first slice — issue #161)

## Purpose

Point the repo at any VistA-family instance (IHS RPMS on IRIS, YottaDB/stock
VistA, WorldVistA) and, **without ever writing to it**, answer two
questions:

1. **Which release does it conform with?** (classification)
2. **What delta must be run to reach a target release?** (prescription)

The instance may be an IHS-provided baseline we have never seen, with
tribe-specific config/data layered on top. We do not assume it equals any build
we produced — we *detect* what it provides and diff against a contract.

## Non-negotiable: never write to the target

The probe reads the instance's **self-describing metadata**, never exercises
behavioral RPCs against a live/unknown instance. Reading a registry or a data
dictionary is structurally incapable of touching a clinical write path.

- Behavioral cucumber/rails tests run **only against rungs we own** — to build
  reference fingerprints and prove capability→behavior. They never touch a
  customer instance.
- On a target instance the reader is restricted to read-only access
  (SELECT-only SQL, or an allowlist of read-only FileMan lister RPCs).

## The declarative surfaces (what we read)

| Surface | File / source | Tells us |
| --- | --- | --- |
| Package versions | PACKAGE `#9.4` | installed package + version (e.g. `PHARMACY 7.0`) |
| Patch history | INSTALL `#9.7` | KIDS builds/patches installed, with dates |
| RPC registry | REMOTE PROCEDURE `#8994` | every installed RPC + tag/routine/return type |
| DD presence | FileMan DD `#0`/`#1` | which files/fields exist |
| SQL surface | `BMW.*` catalog | BPRM raw-SQL table/column schema (**IRIS/RPMS only, optional face**) |

`$$PATCH^XPDUTL` / `$$VERSION^XPDUTL` are read-only KIDS utilities that read the
same INSTALL/PACKAGE data.

## Backend adapters (non-IRIS backends)

`CiaClient` (XWB, :9100) and `BmxClient` (BMX, :9200) both route to the same
registry `^XWB(8994)`; XWB is universal across the VistA family. So the portable
reader works on IRIS/RPMS **and** YottaDB/stock VistA and
WorldVistA. `BMW.*` exists only on IRIS/RPMS, so it is an optional face
keyed on backend.

    Reader (interface: #fingerprint -> Fingerprint)
    ├── FixtureReader   — loads a committed YAML fingerprint (build-free CI/tests)
    ├── BrokerReader    — portable; read-only FileMan lister RPCs via Cia/Bmx
    │                     (allowlist: DDR LISTER, DDR GETS ENTRY DATA,
    │                      XWB FILE LIST, XWB API LIST, …). Works on any backend.
    └── IrisSqlReader   — IRIS only; SELECT-only %FileMan.* + system catalog;
                          adds the BMW.* face. (follow-up)

All adapters emit the **same** `Fingerprint`, tagged with backend + access method.

## Fingerprint schema (committed YAML)

```yaml
backend: iris_rpms          # iris_rpms | yottadb_vista | worldvista
lineage: rpms               # rpms | vista | worldvista
release: null               # set on reference fingerprints (e.g. bcer-8.0); null on probed targets
source:
  kind: broker_dump         # broker_dump | iris_sql | fixture
  captured_at: "2026-06-07"
  note: "file 8994 export from staging"
rpcs:                       # PROVISIONS — the RPC registry
  "XWB ECHO STRING": { tag: ECHO1, routine: XWBZ1, return_type: P }
  "DDR LISTER":      { tag: LISTC, routine: DDR,   return_type: R }
packages: {}                # #9.4 — { "PHARMACY": "7.0" }  (ingest PACKAGES=packages_9_4.txt)
patches: []                 # #9.7 — ["APSP*1.0*70", ...]   (empty until captured)
bmw_tables: {}              # optional IRIS face — { "BMW.PATIENT": [col, col] }
```

A **reference** fingerprint is the same shape with `release` set; captured once
per rung (follow-up: emitted by rpms-ops at release-cut, pinned here).

## Requirements (what our code needs)

Requirements are declared symbolically and resolve to a set of RPC names (and,
later, packages/patches/BMW tables). Sources:

- `ServerCapabilities::FEATURE_RPCS` — existing symbolic feature → RPC map.
- `mappings.rb` — every `DataMapper` declares an `m.rpc`.
- Client capability manifests (factory plan) — the per-client requirement set.

**Conformance = requirements ⊆ provisions.**

## Classification

Given a target `Fingerprint` and a set of reference fingerprints, score each
reference by how well the target's provisions cover it and report the best
match plus neighbors:

- `coverage(ref)` = |ref.rpcs ∩ target.rpcs| / |ref.rpcs|
- Best match = highest coverage; ties broken by smallest symmetric difference.
- Output: `{ classified_as:, coverage:, package_coverage:, ranked: [...] }`. A
  target between rungs reports e.g. `bcer-7.0 (coverage 1.0), partial bcer-8.0
  (coverage 0.62)`.
- **Package signal (additive):** each ranked entry also carries
  `package_coverage(ref)` = fraction of the reference's `#9.4` packages whose
  required version the target meets (`nil` when the reference declares no
  packages — "no data", deliberately distinct from 1.0). It never influences
  ranking or `classified_as`; RPC coverage stays the classification signal.

## Delta (prescription)

Given a target and a *required* release reference (or a requirements set):

- `missing = required.rpcs − target.rpcs` (must be provisioned to reach target)
- `extra   = target.rpcs − required.rpcs` (present but not required; informational)
- **Package gaps (`Delta.package_gaps`):** the `#9.4` face of the prescription —
  required packages the target lacks or holds at a *lower* version, as
  `{ name => { required:, actual: } }` (name-sorted; `actual` nil = absent,
  `""` = installed with no recorded version). Versions compare via
  `Gem::Version` where both parse; unparseable outliers (e.g. `.5`) fall back
  to string equality. Informational for now — the conformance gate stays
  RPC-based until per-rung package references are authoritative.
- Later: map `missing` RPCs → the KIDS patches / tribe migrations that provide
  them (capability→patch map), so the delta is *actionable*, not descriptive.

## Runner

```
rake conformance:probe TARGET=<fingerprint.yml> [REQUIRED=<reference.yml>]
```

For the first slice `TARGET`/`REQUIRED` are committed fixtures (FixtureReader).
Live `BrokerReader`/`IrisSqlReader` land in a follow-up; the runner interface
does not change when they do.

## First slice scope (this PR)

- `RpmsRpc::Conformance`: `Fingerprint`, `Reader`+`FixtureReader`,
  `Classifier`, `Delta`.
- Fixtures: a staging fingerprint seeded from the real 2026-06-07 file-8994
  dump (representative subset), plus seed reference fingerprints for two rungs.
- `rake conformance:probe`; minitest coverage.
- **Out of scope (follow-ups):** live reader adapters, all-5-rung reference
  fingerprints (need booted releases / rpms-ops emit), capability→patch map,
  packages/patches/BMW faces populated.
