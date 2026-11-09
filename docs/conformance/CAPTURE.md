# The pinned rpms-ops build signature

rpms-rpc conforms to the RPC signature of a named rpms-ops build (#160, #222).
A reference fingerprint answers "what does build X provide?", and it is only a
reference if its bytes trace to a real, artifact-bound capture of that build.
rpms-ops produces that capture as a build output; this repo pins it like a
dependency. Nothing here boots an engine.

## The contract

For every gated release tag, rpms-ops attaches the RPC surface that build serves to the GitHub
release (rpms-ops `bin/release_inventory.sh` and `bin/release_rpcs_json.rb`, run by the gate
workflows, then `bin/publish_inventory.sh`). `conformance:pin` takes the one document of that
surface and the faces it does not carry (rpms-rpc#406):

| asset | content |
| --- | --- |
| `<tag>-rpcs.json` | **the RPC surface** (rpms-ops#732; schema `rpcs.v1`, or `rpcs.v2` with #8994's text, rpms-ops#877): a header naming the build (`schema`, `tag`, `commit`, `engine`, `rpms_version`) and the sha256 of each raw file it was projected from (`inputs`), then one record per registered RPC in byte order of its name: entry point and formals, #8994 codes, INPUT PARAMETERs, #9.4 package, and its **reach** (class, routine/tag present, contexts, exemptions). rpms-ops `bin/release_rpcs_json.rb` is the format's authority. |
| `<tag>-packages_9_4.txt` | `PREFIX^NAME^VERSION`, one installed package per line (the fingerprint's packages face: rpcs.json names only the packages that own an RPC) |
| `<tag>-contexts_19_05.txt` | which **context** (option) serves which RPC: one row per `#19.05` RPC multiple entry, tab-separated and byte-sorted under the header `OPTION TYPE LOCK RPC RPC_KEY RPC_RULES`; `LOCK` is `#19` piece 6 (rpms-ops#626, from `bcer-9.0-20261012-e7923a4-ydb`) |
| `<tag>-INVENTORY-PROVENANCE.json` | engine, M backend, container, `artifact_bound`, `artifact_sha256`, per-dump sha256 + record counts, inventory tool commit; the reach face's sha256 + class counts (`rpc_reach`), the signatures' sha256 + counts (`rpc_signatures`), and for `-ydb` the image by digest (`image`, rpms-ops#727) |
| `<tag>-INVENTORY.sha256` | sidecar over the raw inventory files (`shasum -a 256 -c`); it does not cover `rpcs.json` |
| `<tag>-PROVENANCE.json` | the build record: `release`, `rpms_ops_commit` (the commit the build was cut from) |

The raw files rpcs.json is projected from (`<tag>-broker_8994.txt`, `-rpc_reach.txt`,
`-rpc_signatures.txt`) stay on the release, and the sidecar still names them; the pin does not
commit them. rpcs.json is bound to them through its `inputs`: each must be the sidecar's sha256.

A build tag is `bcer-<RPMS version>-<yyyymmdd>-<rpms-ops short commit>-<ydb|iris>`.
The RPMS version and engine come from the tag; the build commit comes from the
build record and must start with the tag's short commit.

On this side (`lib/rpms_rpc/conformance/inventory_lock.rb`):

| file | role |
| --- | --- |
| `data/fingerprints/rpms-ops.lock.yml` | **the pin**: tag, RPMS version, engine, build commit, artifact sha, image (by digest), inventory tool commit, reach class counts, sha256 per asset, counts. Written by `conformance:pin`; never hand-edited. |
| `data/inventories/<tag>/` | **the signature**: the six assets, byte for byte. |
| `data/fingerprints/uncallable_exceptions.yml` | RPCs the gem sends that a pinned build does not let a client call, kept only as a recorded build defect with its upstream issue. Printed on every run; a stale entry fails. |

## One reader

`lib/rpms_rpc/conformance/build_surface.rb` (`RpmsRpc::Conformance::BuildSurface`) is the only
reader of the build's surface. `BuildSurface.load(dir, tag)` reads `<tag>-rpcs.json` and returns
the build's RPCs in byte order of name, each with its registry fields (`tag`, `routine`,
`return_type`, `availability`, `inactive`, `entry_point`), its reach (`reach`, `callable?`,
`routine_present`, `tag_present`, `contexts`, `exempt_on`), its signature (`params` with
name/type/required, `formals`, and with `rpcs.v2` the #8994 text: `description`, each parameter's
description, max_length and sequence, `returns`, `word_wrap`, `version`) and its package. It refuses
a schema it does not know, a document for another tag, an empty, repeated or unsorted list, a reach
class it does not know, and formals-sourced parameters that disagree with the formals. Checksums
are `InventoryLock`'s job; it verifies the bytes and then reads them through this class.

With `<tag>-contexts_19_05.txt` pinned, `contexts?` is true and the surface answers the broker's context
questions: `bind_refusal(option, keys:)` (the option is not a context on the build, or its `LOCK` is a key not
held) and `context_refusal(option, rpc, keys:)` (the bound option's RPC multiple does not list the RPC, or its
`RPC_KEY` is not held; XUS SIGNON's RPCs and broker-exempt ones are never refused, and `RPC_RULES` is not run).
`MockClient#enforce_contexts!(surface, keys:)` holds a mock to them, so a test sees the refusal the server would
give (rpms-rpc#416).

The registered-names gate, the callable gate, `Features`, `rake rpc:exclusions`, `rake rpc:coverage`,
`rake rpc:api_coverage`, `conformance:pin`/`check` and `rake openapi:surface` all read through it.
The per-file parsers of `broker_8994.txt` and `rpc_reach.txt` (and of `rpc_signatures.txt`) are gone
(#394 AC 4, #406). Two flat readers stay, each for a contract with rpms-ops rather than a pinned
release: `rake conformance:ingest DUMP=` reads the flat #8994 dump `bin/assess_instance.sh --emit-flat`
writes for an instance, and `RpcCoverage.load_registry` reads the names file rpms-ops
`bin/rpms_rpc_live_score.rb` scores with.
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
bundle exec rake conformance:pin RELEASE=bcer-9.0-20261012-e7923a4-ydb
# 1. gh release download the six assets above (REPO= overrides lakeraven/rpms-ops)
# 2. each file's sha256 must equal the release's asset digest
# 3. verify: sidecar matches the bytes it covers; provenance artifact_bound, release_tag == tag,
#    engine == the tag's, has rpc_reach and rpc_signatures faces, image.digest == artifact_sha256;
#    build record release == tag, rpms_ops_commit starts with the tag's commit;
#    rpcs.json names this tag, engine, RPMS version and commit, each of its inputs is the
#    sidecar's sha256, it lists as many RPCs as the provenance counts, in the same reach classes
# 4. ingest rpcs.json -> data/fingerprints/references/<tag>.yml (backend iris_rpms | yottadb_rpms)
# 5. record the pin in data/fingerprints/rpms-ops.lock.yml
bundle exec rake rpc:exclusions
git add data/rpc_coverage/exclusions.yml data/fingerprints/rpms-ops.lock.yml data/fingerprints/references/<tag>.yml data/inventories/<tag>
```

A release published before rpms-ops#732 has no rpcs.json and cannot be pinned until it is re-gated.
After a re-pin, run `rake rpc:exclusions` (the unreachable exclusions come from the pinned rpcs.json).

`SOURCE=<dir>` copies the six assets from a directory instead of downloading them
(a workflow artifact, say), and skips step 2.
`ENV=` overrides the fingerprint name (default `references/<tag>`).
To move `rake rpc:coverage` to the new build, point `release`, `registry` and
`packages` in `data/rpc_coverage/config.yml` at it.
To retire the build it replaces, remove that tag's entry from the lock through
`InventoryLock` (`entries.delete(tag)`, then `save`, which keeps the header and order), delete its
`data/inventories/<tag>/` and its entries in `data/fingerprints/uncallable_exceptions.yml`.
Its `references/<tag>.yml` fingerprint stays, as a rung `conformance:probe` ranks against.

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
