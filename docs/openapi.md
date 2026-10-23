# The OpenAPI documents

rpms-rpc generates two OpenAPI 3.1 documents (#395), and this page is where their fields are defined.

| Document | Task | Release asset | What it describes |
|---|---|---|---|
| RPC surface | `rake openapi:surface` | `rpc-surface.openapi.json` | every RPC the pinned build registers in REMOTE PROCEDURE (#8994), sent over the broker by name, from its `<tag>-rpcs.json` |
| Client API | `rake openapi:api` | `client-api.openapi.json` | the gem's public methods, each addressed as a resource, with the RPCs behind it |

`rake openapi` writes both into `pkg/openapi/` (`OUT=` overrides the path of one).
Each task refuses to report success unless its document validates against the OpenAPI 3.1 schema, every verb and path is unique (path parameters compared by position, not name), every operationId is unique, and every path parameter is declared.
The same inputs give byte-identical output: nothing in either document is a timestamp.

## Where the facts come from

**The surface** reads ONE rpms-ops file: the pinned build's `<tag>-rpcs.json` (rpms-ops#732), the structured view rpms-ops projects from a release's raw inventory files.
`rake openapi:pin RELEASE=<tag>` pins it the way `conformance:pin` pins the raw files:
- it downloads the file and checks it against the release asset's digest;
- it fetches rpms-ops's `releases/schema/rpcs.v1.schema.json` at the build's own commit;
- it validates the file and commits both under `data/openapi/`, with `data/openapi/rpcs.lock.yml` recording the tag, the sha256 of each, and the schema's source.

Before anything is read, `openapi:surface` proves the pin offline:
- the file's sha256 is the pinned one;
- its `schema` field is `rpcs.v1`;
- it validates against the closed schema;
- its header names the pinned tag.

It reads the file through `RpmsRpc::Conformance::BuildSurface.from_rpcs_json`, the second constructor of the one reader of rpms-ops files (#394).

**rpcs.v1 and rpcs.v2.**
A release keeps the schema it was published with: `bcer-9.0-20261012-e7923a4-ydb`, the build pinned now, publishes rpcs.v1, and releases gated after rpms-ops#877 publish rpcs.v2.
`openapi:pin` fetches the schema the file's `schema` field names, at the build's own commit, and the lock records which (`schema`).
rpcs.v2 adds #8994's text, kept as stored (each byte is the Latin-1 code point of its value).
From an rpcs.v2 file the surface is the document the raw files give, field for field: on 1012, a v2 file regenerated with rpms-ops#877's generator gives a document byte-identical to the one from the raw files.

**What rpcs.v1 does not carry.**
It has no #8994 text and none of a few #8994 fields, so the surface leaves out what it would otherwise take from them:
- the operation's DESCRIPTION (the description then says the file lacks it);
- INPUT PARAMETER descriptions, MAX LENGTH (`maxLength`) and SEQUENCE NUMBER (`x-rpms-sequence`);
- RETURN PARAMETER DESCRIPTION (the response is described by its type);
- WORD WRAP (`word_wrap` reads `false`) and VERSION.

On `bcer-9.0-20261012-e7923a4-ydb` that is 1,733 operation descriptions, 1,829 argument descriptions, 571 maximum lengths, 1,360 sequence numbers and 1,028 reply descriptions.
Everything else matches what the raw files give: every verb and path, the tags, the counts, entry points, reach and contexts, packages, formals, and the order, type and required flag of each argument.
rpcs.v2 carries all of them; re-pinning to the first release that publishes it (`rake openapi:pin RELEASE=<tag>`) restores them, with no code change.

**Which build.**
Both documents name the same build.
`data/rpc_coverage/config.yml`, which the client API's analysis reads, and `data/openapi/rpcs.lock.yml`, which the surface reads, both pin `bcer-9.0-20261012-e7923a4-ydb`.
`rake openapi` refuses to report success when the two documents' `x-rpms-build.tag` differ, and a test holds the defaults to the same tag.
The surface keeps a pin of its own because `conformance:pin` does not fetch `<tag>-rpcs.json`, so a re-pin is both commands with the same tag: `rake conformance:pin RELEASE=<tag>` and `rake openapi:pin RELEASE=<tag>`.

**The client API** runs `rake rpc:api_coverage`'s analysis in process (`METHODS=<file>` reads a JSON it wrote instead); its build is the one `data/rpc_coverage/config.yml` pins.

## Publishing

`.github/workflows/openapi-release.yml` runs when a GitHub release of the gem is published.
It generates both documents at the release's tag, attaches them as release assets, downloads them back and compares them byte for byte.
A consumer fetches them by the gem's tag:

```sh
gh release download v0.4.0 -R lakeraven/rpms-rpc -p rpc-surface.openapi.json -p client-api.openapi.json
```

or by URL, `https://github.com/lakeraven/rpms-rpc/releases/download/<tag>/<asset>` (`releases/latest/download/<asset>` for the newest release).
To attach them to an existing release, run the workflow by hand with that tag.

## Provenance, in both documents

| Field | Meaning |
|---|---|
| `x-rpms-gem.name`, `.version` | `rpms-rpc` and `RpmsRpc::VERSION` |
| `x-rpms-gem.commit` | the gem commit the document was generated from (`GEM_COMMIT=` overrides `git rev-parse HEAD`) |
| `x-rpms-gem.dirty` | `true` when the checkout had uncommitted changes, so the document is not exactly the commit's; absent otherwise |
| `x-rpms-build.tag` | the rpms-ops build tag (`bcer-9.0-20261012-e7923a4-ydb`) |

The surface's `x-rpms-build` also carries `rpms_version`, `engine`, `rpms_ops_commit` (the rpcs.json header's), `source` (`<tag>-rpcs.json`, its sha256 and its `schema`) and `inputs` (each raw file rpms-ops projected it from, with the sha256 the header names).
Its `info.version` is the RPMS version (`bcer-9.0`); the client API's is the gem version.

## The RPC surface

Each RPC is one operation, `<verb> /<package>/<resource>`, derived from the RPC's name (see "Addressing" below).
The path is an address for reading only: the `summary` and `x-rpms.rpc` are the exact name the broker is sent, and `operationId` is that name as a snake-case slug.
The one server is `broker://{host}:{port}` and `security` is empty: sign-on happens on the broker, not over HTTP.
The tag is the package: the #9.4 PREFIX that is the longest prefix of the RPC's routine (`UNASSIGNED` when none is).
An RPC whose INACTIVE blocks a local call (`INACTIVE`, `LOCAL INACTIVE (ACTIVE REMOTELY)`) is marked `deprecated`.

**Arguments** (`requestBody`, media type `application/x-rpms-rpc`) are in broker order, `x-position` from 1.
They are #8994's INPUT PARAMETERs when the RPC has any, in the order the walk reads them (SEQUENCE NUMBER is empty on many and repeated on some), otherwise the entry point's formals after the first (the reply variable).
The reply (`responses.200`) is a string for SINGLE VALUE and GLOBAL INSTANCE and an array of lines otherwise, described by RETURN PARAMETER DESCRIPTION when there is one.

| Field | Meaning |
|---|---|
| `x-rpms.rpc` | the RPC's name as registered in #8994 |
| `x-rpms.entry_point` | `TAG^ROUTINE` as #8994 stores it (`^ROUTINE` when TAG is empty: the routine's first line); absent when neither is set |
| `x-rpms.routine`, `.tag` | the two pieces, as stored (`""` when empty) |
| `x-rpms.routine_present`, `.tag_present` | whether the routine, and the tag in it, exist on the build's image |
| `x-rpms.formals` | the entry point's formal list, as the walk read it |
| `x-rpms.return_value_type` | `SINGLE VALUE`, `ARRAY`, `WORD PROCESSING`, `GLOBAL ARRAY` or `GLOBAL INSTANCE` |
| `x-rpms.availability` | `PUBLIC`, `SUBSCRIPTION`, `AGREEMENT` or `RESTRICTED` (`""` when unset) |
| `x-rpms.inactive` | `ACTIVE`, `INACTIVE`, `LOCAL INACTIVE (ACTIVE REMOTELY)` or `REMOTE INACTIVE (ACTIVE LOCALLY)` |
| `x-rpms.word_wrap` | #8994 WORD WRAP ON (`false` when the source is rpcs.v1, which does not carry it) |
| `x-rpms.version` | #8994 VERSION, when set and carried |
| `x-rpms.params_source` | where the arguments came from: `8994` (INPUT PARAMETER), `routine` (the formals) or `none` |
| `x-rpms.package` | `{prefix, name, version}` of the #9.4 package; absent when none matches |
| `x-rpms.reach` | from the build's reach face: `class` (`client-callable`, `broker-exempt`, `no-context`, `no-entry-point`, `no-routine`, `inactive`, `out-of-order`), `contexts` (the options whose RPC multiple lists it), `exempt_on` (the broker lines it needs no context on) |
| `x-rpms.verb_rule`, `.path_rule` | which addressing rule chose the verb, and which uniqueness tier the path |

On an argument:

| Field | Meaning |
|---|---|
| `x-position` | its place in the broker call, from 1 |
| `x-rpms-sequence` | #8994 SEQUENCE NUMBER as stored, when there is one and the source carries it |
| `x-rpms-name` | the name as registered, when #8994 registers one name twice for an RPC and the repeat is keyed `<name> (2)` |
| `x-rpms-param-type` | `LITERAL`, `LIST`, `WORD PROCESSING` or `REFERENCE` |

`x-rpms-counts` totals the document: `rpcs`, `verbs`, `path_rules`, `params_source`, `parameters` (arguments by source; the `8994` count equals the walk's `parameters=`) and `reach` (RPCs per reach class).

### Addressing

Words are the RPC name split on spaces.
The first word is the namespace (`XUS`, `ORWPT`) and is dropped; a one-word name (`MAGGPATINFO`) keeps its word, since its namespace is fused in.
The verb word, when there is one, is dropped too; the rest, in order and slugged, is the resource.
A name that is only a namespace and a verb (`ORWDX SAVE`) keeps the verb word.
Words match whole (`SETUP` is not `SET`).
A verb word is looked for right after the namespace, then at the end, then in between; read nouns count only when there is no verb word, and stay in the path.

| Rule | Verb | Words |
|---|---|---|
| read | GET | GET, GETS, FIND, LOOKUP, SEARCH, SRCH, SELECT, QUERY, FETCH, RETRIEVE; fused `GET<thing>` (`GETCATS`, the remainder stays); fused `ALL<things>` (`ALLKEYS`, kept whole; not `ALLERG*`) |
| write | PUT | SET, UPDATE, UPD, EDIT, FILE, STORE, PUT, CHANGE, MODIFY, REPLACE |
| delete | DELETE | DEL, DELETE, REMOVE, PURGE, KILL |
| act | POST | ADD, NEW, CREATE, SAVE, SEND, VALIDATE, VERIFY, CHECK, CHK, SIGN, QUEUE, LOCK, UNLOCK, REGISTER, UNREGISTER, RUN, PRINT, CANCEL, CLONE, COPY, IMPORT, EXPORT, UPLOAD, NOTIFY, ACKNOWLEDGE, BUILD, REFRESH, CLEAR, FLUSH, START, STOP, CLOSE, RENEW, FORWARD |
| read noun | GET | LIST, LISTS, LST, REPORT, REPORTS, RPT, INFO, DETAIL, DETAILS, SUMMARY, VIEW, DISPLAY (kept in the path) |
| default | POST | no verb word: an RPC may change state |

`XUS DIVISION GET` is `GET /kernel/division`, `XUS DIVISION SET` is `PUT /kernel/division`, and `BMC REFERRAL STATUS UPDATE` is `PUT /referred-care-info-system/referral-status`.

Two RPCs of one package with the same verb and path both move up a tier until none clash: `base`, then `verb word kept` (`.../event-register`), then `namespace` (`.../orwpce/delete`), then `namespace and verb word`.
Generation refuses names that still clash after the last tier.

## The client API

Each operation is one public method a registered RPC backs.
`operationId` is `Module.method`, the `summary` is the Ruby call (`RpmsRpc::Patient.find(dfn)`), and the one tag is the method's collection (`/patients`).
Modules that share a collection share its tag: `Authentication` and `UserManagement` are both `/users`, and every `BehavioralHealth` module is `/behavioral-health`.
Path parameters are the method's identifier arguments; query parameters (GET, DELETE) or a JSON body (POST, PUT) carry the rest.
Unproven operations are not `deprecated`: they are waiting for a live spec, not going away.

| Field | Meaning |
|---|---|
| `x-rpms.ruby` | the Ruby call |
| `x-rpms.rpcs[]` | each RPC the method sends: `name`, `registered` on the build, `entry_point`, `reach` (its class on the build), `via` (`mapping :name` or `literal`) |
| `x-rpms.status` | `proven` (a live spec calls the method) or `not_in_contract` (none does yet; ADR 0010) |
| `x-rpms.live_specs`, `.personas` | the `file:line` of each live call, and the personas those specs run as |
| `x-rpms.rule` | which mapping rule placed it: `read`, `query`, `query-sub-path`, `inquiry`, `create`, `write`, `delete`, `action`, `predicate`, `for`, `noun` or `retry-class` |
| `x-rpms.folded` | other methods that are the same query (same module, same RPCs, same verb and path), folded in as optional query parameters |

`x-rpms-api` totals the document: `methods` (public methods), `operations`, `proven`, `verbs`, `excluded` (methods that send no RPC, `no_rpc`; whose RPC name static analysis could not resolve, `unresolved`; or that send an unregistered RPC, `unregistered`), `folded`, and `collections` (`name`, `base`, `modules`, `operations`, `proven`).

### Mapping rules

Each module's collection is written down once, in `OpenApi::ClientApi::RESOURCES` (`Adt` is `/admissions`, `Scheduling` is `/appointments`); any other module is its name, plural and kebab-cased.

**Identifiers.**
An argument is an identifier when it is required (positional or keyword) and named `dfn`, `patient_dfn`, `duz`, `user_duz`, `file`, `iens`, `ien` or `<x>_ien`; a user is one only as the first argument.
`ien` and the module's own identifiers name a member of its collection (`/problems/{ien}`).
`dfn` is a patient, `duz` a user, `note_ien` a progress note, `iens` a FileMan entry, and `<x>_ien` a member of the collection the method name spells up to `<x>` (`treatment_plan_narrative(plan_ien)` is `/treatment-plans/{plan_ien}/narrative`).

**Scope.**
When the first identifier is a patient, a user or a progress note, or names the `<x>` of a `_for_<x>` method, the path starts there: `Procedure.for_patient(dfn)` is `GET /patients/{dfn}/procedures`.

**The verb**, from the method name's first word:

| Rule | Verb | Words | Path |
|---|---|---|---|
| read | GET | find, get, gets, fetch, list, lister, show, detail, details | the word is dropped: `find(dfn)` is `GET /patients/{dfn}` |
| query | GET | search, lookup, find_by_&lt;x&gt; | the collection, arguments as query parameters |
| inquiry | GET | check, which, can, is, has, authorize, bootstrap | the word stays: `GET /progress-notes/{note_ien}/authorize` |
| create | POST | add, create, new, record, register, save | the collection; identifiers other than the scope go in the body |
| write | PUT | update, set, file, filer, change | the item, or the rest of the name |
| delete | DELETE | delete, remove | the item |
| action | POST | authenticate, cancel, checkin, complete, generate, inactivate, init, lock, mark, open, print, send, sign, uncancel, unlock, validate, verify | `POST /referrals/{ien}/cancel` |
| predicate | GET | a name ending in `?` | `expired?` is `GET /orders/{order_ien}/expired` |
| noun | GET | any other first word | a sub-resource: `GET /patients/{dfn}/brief-header` |
| retry-class | POST | an inferred GET published as POST | the same path, when the retry class is not `:read`, and when a name has no verb word and no retry row. The unchecked names frozen in `data/openapi/write_class_get_baseline.txt` keep the inferred GET; the list may only shrink, and only when a method's retry class is verified `:read` |

A method name with no verb word infers GET, unlike an RPC name (POST). With no retry row it is published POST at that inferred path, so the remaining words stay and two nouns in one module do not collide. A named verb with no retry row keeps its inferred verb. A `:read` method keeps the inferred verb, path and rule.

**Two queries on one collection.**
A plain read of the collection keeps it, then `search`, then `lookup`, then `find_by_<x>`.
A later query with the same module and RPCs is folded into the first; any other keeps its sub-path (`Patient.lookup` is `GET /patients/lookup`).
Any other clash is refused.

**What the path already says is dropped** from the remaining words: the collection's own name, the scope's member, the words that named an identifier's collection, and `detail`.
