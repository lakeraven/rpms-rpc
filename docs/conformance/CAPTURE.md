# The openrpms release signature

rpms-rpc is tested against the RPC signature of the latest published openrpms YottaDB release
(#160, #222, #724). A reference fingerprint answers "what does build X provide?", and it is only a
reference if its bytes trace to a real, artifact-bound capture of that build. openrpms produces that
capture as a build output; this repo fetches it when the tests run. Nothing is pinned or committed per
release, and nothing here boots an engine.
Which pin lives where, across openrpms, rpms-rpc, lakeraven-ehr and cloud-rpms, is stated once, in openrpms
[docs/PINS.md](https://github.com/lakeraven/openrpms/blob/main/docs/PINS.md).

## The contract

For every gated release tag, openrpms attaches the RPC surface that build serves to the GitHub
release (openrpms `bin/release_inventory.sh` and `bin/release_rpcs_json.rb`, run by the gate
workflows, then `bin/publish_inventory.sh`). `rake openrpms:fetch` takes the one document of that
surface and the faces it does not carry (rpms-rpc#406):

| asset | content |
| --- | --- |
| `<tag>-rpcs.json` | **the RPC surface** (openrpms#732; schema `rpcs.v1`, or `rpcs.v2` with #8994's text, openrpms#877): a header naming the build (`schema`, `tag`, `commit`, `engine`, `rpms_version`) and the sha256 of each raw file it was projected from (`inputs`), then one record per registered RPC in byte order of its name: entry point and formals, #8994 codes, INPUT PARAMETERs, #9.4 package, and its **reach** (class, routine/tag present, contexts, exemptions). openrpms `bin/release_rpcs_json.rb` is the format's authority. |
| `<tag>-packages_9_4.txt` | `PREFIX^NAME^VERSION`, one installed package per line (the fingerprint's packages face: rpcs.json names only the packages that own an RPC) |
| `<tag>-contexts_19_05.txt` | which **context** (option) serves which RPC: one row per `#19.05` RPC multiple entry, tab-separated and byte-sorted under the header `OPTION TYPE LOCK RPC RPC_KEY RPC_RULES`; `LOCK` is `#19` piece 6 (openrpms#626, from `bcer-9.0-20261012-e7923a4-ydb`) |
| `<tag>-INVENTORY-PROVENANCE.json` | engine, M backend, container, `artifact_bound`, `artifact_sha256`, per-dump sha256 + record counts, inventory tool commit; the reach face's sha256 + class counts (`rpc_reach`), the signatures' sha256 + counts (`rpc_signatures`), and for `-ydb` the image by digest (`image`, openrpms#727) |
| `<tag>-INVENTORY.sha256` | sidecar over the raw inventory files (`shasum -a 256 -c`); it does not cover `rpcs.json` |
| `<tag>-PROVENANCE.json` | the build record: `release`, `rpms_ops_commit` (the commit the build was cut from) |

The raw files rpcs.json is projected from (`<tag>-broker_8994.txt`, `-rpc_reach.txt`,
`-rpc_signatures.txt`) stay on the release, and the sidecar still names them; the fetch does not
download them. rpcs.json is bound to them through its `inputs`: each must be the sidecar's sha256.

A build tag is `bcer-<RPMS version>-<yyyymmdd>-<openrpms short commit>-<ydb|iris>`.
The RPMS version and engine come from the tag; the build commit comes from the
build record and must start with the tag's short commit.

On this side (`lib/rpms_rpc/conformance/release_inventory.rb`, `rake openrpms:fetch`):

| what | role |
| --- | --- |
| which release | `OPENRPMS_RELEASE=<tag>` when set; otherwise the newest published (not draft, not prerelease) `bcer-*-ydb` release that carries every asset above. Looked up with `gh api` each time, so it moves when openrpms publishes. |
| `tmp/openrpms/<tag>/` | the downloaded assets (not committed; `OPENRPMS_INVENTORIES=` moves the cache). Each byte must equal the release's asset digest, and the set must verify (below) before anything reads it. |
| `tmp/openrpms/current.json` | the release this checkout tests against: tag, how it was chosen, image by digest, build commit, rpcs.json sha256. Features, the gates, `rpc:coverage` and the live specs' build label read it offline. CI publishes it, with the test result, as the `tested-against` artifact. |
| `test/fixtures/inventories/<tag>/` | a small inventory cut verbatim from a real release (`tools/fixture_inventory.rb`, names in `test/fixtures/release_inventory/names.txt`), so the readers' unit tests run offline. |
| `data/fingerprints/uncallable_exceptions.yml` | RPCs the gem sends that the release under test does not let a client call, kept only as a recorded build defect with its upstream issue. Printed on every run; a stale entry fails. |

Verification: the sidecar matches the bytes it covers; the provenance is `artifact_bound`, its
`release_tag` is the tag, its engine the tag's, it has the `rpc_reach` and `rpc_signatures` faces and
`image.digest == artifact_sha256`; the build record's release is the tag and its `rpms_ops_commit`
starts with the tag's commit; rpcs.json names this tag, engine, RPMS version and commit, each of its
`inputs` is the sidecar's sha256, and it lists as many RPCs, in the same reach classes, as the
provenance counts. A release that fails is not tested against: a gap is data, fixed in the build.

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
are `ReleaseInventory`'s job; it verifies the bytes and then reads them through this class.

With `<tag>-contexts_19_05.txt` present, `contexts?` is true and the surface answers the broker's context
questions: `bind_refusal(option, keys:)` (the option is not a context on the build, or its `LOCK` is a key not
held) and `context_refusal(option, rpc, keys:)` (the bound option's RPC multiple does not list the RPC, or its
`RPC_KEY` is not held; XUS SIGNON's RPCs and broker-exempt ones are never refused, and `RPC_RULES` is not run).
`MockClient#enforce_contexts!(surface, keys:)` holds a mock to them, so a test sees the refusal the server would
give (rpms-rpc#416).

The registered-names gate, the callable gate, `Features`, `rake rpc:exclusions`, `rake rpc:coverage`,
`rake rpc:api_coverage`, `rake openrpms:fetch` and `rake openapi:surface` all read through it.
The per-file parsers of `broker_8994.txt` and `rpc_reach.txt` (and of `rpc_signatures.txt`) are gone
(#394 AC 4, #406). Two flat readers stay, each for a contract with openrpms rather than a published
release: `rake conformance:ingest DUMP=` reads the flat #8994 dump `bin/assess_instance.sh --emit-flat`
writes for an instance, and `RpcCoverage.load_registry` reads the names file openrpms
`bin/rpms_rpc_live_score.rb` scores with.

## What the gates read

All of these read the release under test; with `OPENRPMS_OFFLINE=1` (the hermetic CI job) each skips
and says so, and the `Release gate` job in `.github/workflows/openrpms-release.yml` runs them with the
release fetched. Without that flag, a release that cannot be fetched fails the test with the reason.

- `test/rpms_rpc/registered_rpc_names_test.rb` (`max_unregistered: 0`): every RPC name the gem uses is
  available on the release: registered, with an entry point (TAG and ROUTINE), and not INACTIVE for
  local use (`.06` = 1 or 2).
- `test/rpms_rpc/callable_rpc_names_test.rb` (#394): every RPC a public method sends (and every other
  RPC name lib/ sends) is **callable** on the release: its reach class is `client-callable` or
  `broker-exempt`. A failure names the RPC, its reach class and the methods that send it. An entry in
  `data/fingerprints/uncallable_exceptions.yml` (a build defect, with its issue) turns a failure into a
  loud warning; a stale entry fails.
- `rake rpc:coverage` counts against the release's registry, minus the RPCs its reach classes call
  uncallable (computed per release) and the reviewed exclusions committed in
  `data/rpc_coverage/exclusions.yml` (`gui_plumbing`, `write_needs_fixture`).

"Callable" is stronger than "available": the entry point must exist on the image,
and a context (or a broker exemption) must allow the RPC. Whether a write files
what it claims is proven by a live call (ADR 0008 rule 4), not by the signature: the `Live` jobs run
`rake test:live` against the same release's image as PROV123 and SYS123.

```sh
bundle exec rake openrpms:fetch                                          # the latest -ydb release
OPENRPMS_RELEASE=bcer-9.0-20261116-2a9b3fe-ydb bundle exec rake openrpms:fetch   # a specific one
bundle exec rake openrpms:current                                        # what this checkout tests against
```

## Reference fingerprints

`data/fingerprints/references/<tag>.yml` were ingested from earlier pinned releases; they stay as the
rungs `conformance:probe` ranks against, unchanged until their owner decides where they live (#724).
The pre-2026-09 seed placeholders (`references/bcer-5.0.yml`, `bcer-8.0.yml`) are not checked, and
`conformance:probe` does not rank against them: a file whose first line says `PLACEHOLDER` is listed as
"Not ranked".

```sh
bundle exec rake conformance:probe TARGET=<some fingerprint>.yml [REQUIRED=references/<tag>.yml]
```

## Raw ingest (no gated release)

`rake conformance:ingest DUMP=<broker_8994.txt> ENV=<name> [PACKAGES=] [RELEASE=] [DAT_SHA=]`
turns a dump into a fingerprint: for a dump you captured yourself (openrpms
`bin/assess_instance.sh --emit-flat --engine <iris|yottadb> ...` against any instance,
including a deployed stack over SSM). The result carries no `source.inventory` face and
is therefore an observation, not a reference; do not put it under `references/`.

## Do not

- Do not commit a release's inventory or pin a tag: the tests look the release up.
- Do not hand-edit a fingerprint or the fixture inventory: regenerate the fixture with `tools/fixture_inventory.rb`.
- Do not test against an inventory whose provenance is not `artifact_bound`: the fetch refuses it (openrpms#482).
- Do not boot rung containers here to capture registries; that is openrpms's build side.
