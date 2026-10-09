# The pinned rpms-ops build signature

rpms-rpc conforms to the RPC signature of a named rpms-ops build (#160, #222).
A reference fingerprint answers "what does build X provide?", and it is only a
reference if its bytes trace to a real, artifact-bound capture of that build.
rpms-ops produces that capture as a build output; this repo pins it like a
dependency. Nothing here boots an engine.

## The contract

For every gated release tag, rpms-ops attaches these assets to the GitHub release
(rpms-ops `bin/release_inventory.sh`, run by the gate workflows, then
`bin/publish_inventory.sh`):

| asset | content |
| --- | --- |
| `<tag>-broker_8994.txt` | one `#8994` 0-node per registered RPC: `NAME^TAG^ROUTINE^RETURN VALUE TYPE^AVAILABILITY^INACTIVE^...` (`^DD(8994)` fields .01-.11, in order) |
| `<tag>-packages_9_4.txt` | `PREFIX^NAME^VERSION`, one installed package per line |
| `<tag>-rpc_reach.txt` | whether each registered RPC is **callable**, same RPCs in the same order: `NAME^REACH^ROUTINE_PRESENT^TAG_PRESENT^CONTEXTS^EXEMPT_ON` (rpms-ops#713) |
| `<tag>-rpc_signatures.txt` | each RPC's #8994 node, DESCRIPTION, INPUT PARAMETERs, RETURN PARAMETER DESCRIPTION and entry-point formals: rpms-ops `bin/m/ZRPCCAT.m`'s tab-separated walk, ending in `EXPLICIT SUCCESS` |
| `<tag>-INVENTORY-PROVENANCE.json` | engine, M backend, container, `artifact_bound`, `artifact_sha256`, per-dump sha256 + record counts, inventory tool commit; the reach face's sha256 + class counts (`rpc_reach`), the signatures' sha256 + counts (`rpc_signatures`), and for `-ydb` the image by digest (`image`, rpms-ops#727) |
| `<tag>-INVENTORY.sha256` | sidecar over the five above (`shasum -a 256 -c`) |
| `<tag>-PROVENANCE.json` | the build record: `release`, `rpms_ops_commit` (the commit the build was cut from) |

A build tag is `bcer-<RPMS version>-<yyyymmdd>-<rpms-ops short commit>-<ydb|iris>`.
The RPMS version and engine come from the tag; the build commit comes from the
build record and must start with the tag's short commit.

On this side (`lib/rpms_rpc/conformance/inventory_lock.rb`):

| file | role |
| --- | --- |
| `data/fingerprints/rpms-ops.lock.yml` | **the pin**: tag, RPMS version, engine, build commit, artifact sha, image (by digest), inventory tool commit, reach class counts, sha256 per asset, counts. Written by `conformance:pin`; never hand-edited. |
| `data/inventories/<tag>/` | **the signature**: the seven assets, byte for byte. |
| `data/fingerprints/uncallable_exceptions.yml` | RPCs the gem sends that a pinned build does not let a client call, kept only as a recorded build defect with its upstream issue. Printed on every run; a stale entry fails. |

## One reader

`lib/rpms_rpc/conformance/build_surface.rb` (`RpmsRpc::Conformance::BuildSurface`) is the only
reader of the pinned files. `BuildSurface.load(dir, tag)` returns the build's RPCs in #8994 order,
each with its registry fields (`tag`, `routine`, `return_type`, `availability`, `inactive`,
`entry_point`), its reach (`reach`, `callable?`, `routine_present`, `tag_present`, `contexts`,
`exempt_on`) and its signature (`description`, `params` with name/type/max_length/required/
description, `returns`, `formals`, `word_wrap`, `version`), plus the packages. It refuses a reach
face or a signatures walk that does not name the registry's RPCs in order, a reach class it does
not know, and a truncated walk. Checksums are `InventoryLock`'s job; it verifies the bytes and
then reads them through this class.

The registered-names gate, the callable gate, `rake rpc:exclusions`, `rake rpc:coverage`,
`rake rpc:api_coverage` and `conformance:pin`/`check` all read through it, and so will the
OpenAPI generator (#395). When rpms-ops publishes one structured file of the surface
(`<tag>-rpcs.json`, rpms-ops#732), it becomes a second constructor of this class and the
per-file parsers go; no caller changes (#394 AC 4).
| `data/fingerprints/references/<tag>.yml` | the fingerprint ingested from exactly those bytes; its `source.inventory` face repeats the build and the shas. |

## What the gates read

- `test/rpms_rpc/registered_rpc_names_test.rb`: every RPC name the gem uses is
  available on every pinned build: registered, with an entry point (TAG and
  ROUTINE), and not INACTIVE for local use (`.06` = 1 or 2).
- `test/rpms_rpc/pinned_build_signature_test.rb`: the lock names the build; the
  committed signature and the fingerprint match the lock; every wire fixture's RPC
  is registered and its `cite:` leads with the entry point the build registers;
  `rake rpc:coverage` reads the pinned signature (`data/rpc_coverage/config.yml`).
- `test/rpms_rpc/callable_rpc_names_test.rb` (#394): every RPC a public method
  sends (and every other RPC name lib/ sends) is **callable** on every pinned build:
  its reach class is `client-callable` or `broker-exempt`. A failure names the RPC,
  its reach class and the methods that send it. An entry in
  `data/fingerprints/uncallable_exceptions.yml` (a build defect, with its issue)
  turns a failure into a loud warning; a stale entry fails.
- `rake conformance:check` runs the same lock check from the command line.

"Callable" is stronger than "available": the entry point must exist on the image,
and a context (or a broker exemption) must allow the RPC. Whether a write files
what it claims is proven by a live call (ADR 0008 rule 4), not by the signature.

## Pin a build

```sh
bundle exec rake conformance:pin RELEASE=bcer-9.0-20260930-8c88e47-ydb
# 1. gh release download the seven assets above (REPO= overrides lakeraven/rpms-ops)
# 2. each file's sha256 must equal the release's asset digest
# 3. verify: sidecar matches bytes; provenance artifact_bound, release_tag == tag,
#    engine == the tag's; registry line count == provenance rpcs records;
#    rpc_reach and rpc_signatures shas and counts == provenance, image.digest == artifact_sha256;
#    the reach face and the signatures walk name the registry's RPCs in order, and the reach
#    class counts == provenance; build record release == tag, rpms_ops_commit starts with the tag's commit
# 4. ingest -> data/fingerprints/references/<tag>.yml (backend iris_rpms | yottadb_rpms)
# 5. record the pin in data/fingerprints/rpms-ops.lock.yml
bundle exec rake rpc:exclusions
git add data/rpc_coverage/exclusions.yml data/fingerprints/rpms-ops.lock.yml data/fingerprints/references/<tag>.yml data/inventories/<tag>
```

A release published before rpms-ops#713 has no reach face and cannot be pinned until it is re-gated.
After a re-pin, run `rake rpc:exclusions` (the unreachable exclusions come from the pinned reach face).

`SOURCE=<dir>` copies the seven assets from a directory instead of downloading them
(a workflow artifact, say), and skips step 2.
`ENV=` overrides the fingerprint name (default `references/<tag>`).
To move `rake rpc:coverage` to the new build, point `release`, `registry` and
`packages` in `data/rpc_coverage/config.yml` at it.

A rejected inventory is not fixed here. A gap is data: fix the build, re-cut, re-pin.

The pre-2026-09 seed placeholders (`references/bcer-5.0.yml`, `bcer-8.0.yml`) are not
pinned and not checked, and `conformance:probe` does not rank against them: a file whose
first line says `PLACEHOLDER` is listed as "Not ranked". They are replaced as their rungs
get an inventory published.

Then, as before:

```sh
bundle exec rake conformance:probe TARGET=<some fingerprint>.yml [REQUIRED=references/<tag>.yml]
```

## Raw ingest (no gated release)

`rake conformance:ingest DUMP=<broker_8994.txt> ENV=<name> [PACKAGES=] [RELEASE=] [DAT_SHA=]`
is the same transformation without the pin: for a dump you captured yourself (rpms-ops
`bin/assess_instance.sh --emit-flat --engine <iris|yottadb> ...` against any instance,
including a deployed stack over SSM). The result carries no `source.inventory` face and
is therefore an observation, not a reference; do not put it under `references/`.

## Do not

- Do not hand-edit a lock entry, a committed signature or a fingerprint: the tests fail, by design.
- Do not pin an inventory whose provenance is not `artifact_bound`: `pin` refuses it (rpms-ops#482).
- Do not boot rung containers here to capture registries; that is rpms-ops's build side.
