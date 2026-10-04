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
| `<tag>-INVENTORY-PROVENANCE.json` | engine, M backend, container, `artifact_bound`, `artifact_sha256`, per-dump sha256 + record counts, inventory tool commit |
| `<tag>-INVENTORY.sha256` | sidecar over the three above (`shasum -a 256 -c`) |
| `<tag>-PROVENANCE.json` | the build record: `release`, `rpms_ops_commit` (the commit the build was cut from) |

A build tag is `bcer-<RPMS version>-<yyyymmdd>-<rpms-ops short commit>-<ydb|iris>`.
The RPMS version and engine come from the tag; the build commit comes from the
build record and must start with the tag's short commit.

On this side (`lib/rpms_rpc/conformance/inventory_lock.rb`):

| file | role |
| --- | --- |
| `data/fingerprints/rpms-ops.lock.yml` | **the pin**: tag, RPMS version, engine, build commit, artifact sha, inventory tool commit, sha256 per asset, counts. Written by `conformance:pin`; never hand-edited. |
| `data/inventories/<tag>/` | **the signature**: the five assets, byte for byte. |
| `data/fingerprints/references/<tag>.yml` | the fingerprint ingested from exactly those bytes; its `source.inventory` face repeats the build and the shas. |

## What the gates read

- `test/rpms_rpc/registered_rpc_names_test.rb`: every RPC name the gem uses is
  available on every pinned build: registered, with an entry point (TAG and
  ROUTINE), and not INACTIVE for local use (`.06` = 1 or 2).
- `test/rpms_rpc/pinned_build_signature_test.rb`: the lock names the build; the
  committed signature and the fingerprint match the lock; every wire fixture's RPC
  is registered and its `cite:` leads with the entry point the build registers;
  `rake rpc:coverage` reads the pinned signature (`data/rpc_coverage/config.yml`).
- `rake conformance:check` runs the same lock check from the command line.

"Callable" is stronger than "available": the entry point must exist on the image,
and a context (or a broker exemption) must allow the RPC. The release inventory
does not carry that yet. It is requested in rpms-ops#713, and the names gate tightens
to "callable" once it does. Whether a write files what it claims is proven by a
live call (ADR 0008 rule 4), not by the signature.

## Pin a build

```sh
bundle exec rake conformance:pin RELEASE=bcer-9.0-20260930-8c88e47-ydb
# 1. gh release download the five assets above (REPO= overrides lakeraven/rpms-ops)
# 2. each file's sha256 must equal the release's asset digest
# 3. verify: sidecar matches bytes; provenance artifact_bound, release_tag == tag,
#    engine == the tag's; registry line count == provenance rpcs records;
#    build record release == tag, rpms_ops_commit starts with the tag's commit
# 4. ingest -> data/fingerprints/references/<tag>.yml (backend iris_rpms | yottadb_rpms)
# 5. record the pin in data/fingerprints/rpms-ops.lock.yml
git add data/fingerprints/rpms-ops.lock.yml data/fingerprints/references/<tag>.yml data/inventories/<tag>
```

`SOURCE=<dir>` copies the five assets from a directory instead of downloading them
(a workflow artifact, say), and skips step 2.
`ENV=` overrides the fingerprint name (default `references/<tag>`).
To move `rake rpc:coverage` to the new build, point `release`, `registry` and
`packages` in `data/rpc_coverage/config.yml` at it.

A rejected inventory is not fixed here. A gap is data: fix the build, re-cut, re-pin.

The pre-2026-09 seed placeholders (`references/bcer-5.0.yml`, `bcer-8.0.yml`) are not
pinned and not checked. They are replaced as their rungs get an inventory published.

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
