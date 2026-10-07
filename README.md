# rpms-rpc

Pure Ruby RPC client for VistA / RPMS — speaks the **CIA/XWB**
(port 9100) and **BMX** (port 9101) broker protocols. No Rails
dependency, no Java, just stdlib.

## Status

Pre-1.0. The wire protocol layer is functional and verified against
the FOIA-RPMS routine sources. See [docs/rpcs.md](docs/rpcs.md) for
the audit trail.

## Why a separate gem?

Historically the VistA RPC client lived inside a Rails app
(the predecessor Rails app). That made it impossible to reuse from non-Rails
consumers — workers, scripts, and other engines that don't want
ActiveSupport on the load path.

This gem owns the RPMS integration boundary:

- Connection lifecycle (`connect`, `disconnect`, `connected?`)
- Authentication (`XUS SIGNON SETUP`, `XUS AV CODE`, cipher encrypt)
- Application context (`XWB CREATE CONTEXT`)
- Parameter encoding for the VistA `1{len}00f{value}\x04` format
- Caret-delimited and XML response parsing
- FileMan date conversions
- HIPAA-aligned PHI sanitizer for log lines
- **DataMapper** — declarative RPC-to-Ruby field mappings
- **MockClient** — hermetic test double with seeded data (field, text_blob, scalar, collection)
- **SecurityKeys / UserRoles / Capabilities** — symbolic RPMS authorization API

What it does **not** include: ActiveRecord models, FHIR clients,
or Rails dependencies. Engine code (lakeraven-ehr, corvid) should
call rpms-rpc's symbolic API — never reference DataMapper mappings,
RPC names, or wire format details directly.

See [ADR 0001](docs/adr/0001-scope-and-no-rails-coupling.md) for
the full scope rationale.

## Installation

Add to your `Gemfile`:

```ruby
gem "rpms-rpc"
```

Then `bundle install`.

Requires Ruby 3.4+.

## Usage

> **The broker connection is plaintext.** XWB, BMX and CIA carry access/verify
> codes and PHI unencrypted, and the gem has no TLS of its own. Reach a broker
> only over a private network, a port forward, or a TLS tunnel. See
> [Transport security](SECURITY.md#transport-security) and
> [`docs/tls.md`](docs/tls.md).

### Loading the gem

```ruby
require "rpms_rpc"
```

loads the public API: configuration (`RpmsRpc.configure`, `client`, `mock!`,
`reset!`), the response mappings, the security-key, role and capability tables,
and every `RpmsRpc::<Api>` module under `lib/rpms_rpc/api/`. It does not open a
socket or pick a broker. A script that needs only one broker client can require
that file alone (`require "rpms_rpc/cia_client"`, below); it carries the
configuration and error sanitizing it needs, and none of the tables.
`require "rpms_rpc/version"` defines `RpmsRpc::VERSION` and nothing else.

### CIA (XWB) — port 9100

```ruby
require "rpms_rpc/cia_client"

client = RpmsRpc::CiaClient.new(host: "vista.example.com", port: 9100)
client.connect
# Real Access / Verify codes. In development you can set
# VISTA_RPC_ENV=development and omit args to fall back to PROV123 / PROV123!!
client.authenticate(ENV.fetch("RPMS_ACCESS_CODE"), ENV.fetch("RPMS_VERIFY_CODE"))
client.create_context("OR CPRS GUI CHART")

result = client.call_rpc("XUS SIGNON SETUP")
# => array of broker environment lines

client.disconnect
```

### BMX — port 9101

```ruby
require "rpms_rpc/bmx_client"

client = RpmsRpc::BmxClient.new(host: "vista.example.com", port: 9101)
client.connect
client.authenticate
client.create_context("OR CPRS GUI CHART")

result = client.call_rpc("XUS SIGNON SETUP")

client.disconnect
```

### Configuration via environment

| Variable             | Default     | Notes                              |
|----------------------|-------------|------------------------------------|
| `VISTA_RPC_HOST`     | `localhost` | Broker hostname                    |
| `VISTA_RPC_PORT`     | `9100` / `9101` / `9200` | Per subclass: `9100` XWB, `9101` BMX, `9200` CIA |
| `VISTA_RPC_TIMEOUT`  | `30`        | Read timeout in seconds            |
| `RPMS_ACCESS_CODE`   | _(required)_ | Access code. In development only, falls back to `PROV123`. |
| `RPMS_VERIFY_CODE`   | _(required)_ | Verify code. In development only, falls back to `PROV123!!`. |
| `VISTA_RPC_ENV`      | _(unset = strict)_ | Set to `development` to opt into the PROV123/PROV123!! fallback. Unset or any other value is treated as production-strict. |

> **Strict-by-default credentials.** Outside a development environment
> (`Rails.env.development?`, or `VISTA_RPC_ENV=development` when running
> without Rails), `#authenticate` will raise `RpmsRpc::Client::CredentialError`
> in any of these cases:
>
> - `RPMS_ACCESS_CODE` / `RPMS_VERIFY_CODE` are missing, blank, or
>   whitespace-only.
> - The resolved access or verify code equals its dev-only `PROV123` /
>   `PROV123!!` value — whether sourced from ENV, the legacy fallback,
>   or passed *explicitly* as an argument to `#authenticate`.
>
> Explicit arguments take the same path as ENV-sourced values, so a
> snippet like `client.authenticate("PROV123", "PROV123!!")` also
> raises in production. This prevents a misconfigured deploy from
> silently talking to the broker as a debug account.

### Interactive console (`bin/console`)

A small REPL for short feedback loops against a real broker. It starts IRB with
one signed-on client, chosen entirely by environment — there are **no defaults
that name a real host or credential**, and it refuses to start (naming what is
missing) if any required setting is absent.

| Variable       | Required | Notes                                                        |
|----------------|----------|--------------------------------------------------------------|
| `BROKER`       | yes      | `cia` (CIANBLIS/VueCentric) or `bmx` (BMXNet/.NET)           |
| `BROKER_HOST`  | yes      | broker host or IP                                            |
| `BROKER_PORT`  | yes      | TCP port (e.g. `19200` local CIA, `29101` local BMX)        |
| `RPMS_ACCESS`  | yes      | access code                                                  |
| `RPMS_VERIFY`  | yes      | verify code                                                  |
| `RPMS_CONTEXT` | no       | an option to bind after sign-on (e.g. `AGGRPC`)              |

```sh
# placeholders — fill in your own host/port/codes
BROKER=cia BROKER_HOST=127.0.0.1 BROKER_PORT=19200 \
  RPMS_ACCESS=... RPMS_VERIFY=... bin/console
```

At the prompt:

```ruby
rpc "ORWU USERINFO"                       # pretty-prints the RAW reply and the PARSED lines
rpc "AGG LOOKUP PATIENTS", "DEMO", "N"    # params are passed straight through
ctx                                       # show the bound context option
ctx "AGGRPC"                              # bind a context option
reconnect                                 # drop and re-establish connect + sign-on (+ RPMS_CONTEXT)
client                                    # the underlying RpmsRpc client

RpmsRpc::Patient.find(4)                  # the public API answers too, through the same client
RpmsRpc::Authentication.held_keys(%w[PROVIDER XUPROGMODE])
```

## Components

| File                          | Purpose                                          |
|-------------------------------|--------------------------------------------------|
| `RpmsRpc::Client`             | Abstract base — auth, cipher, socket helpers     |
| `RpmsRpc::CiaClient`          | CIA wire protocol (the VueCentric broker)        |
| `RpmsRpc::BmxClient`          | BMX wire protocol (port 9101)                    |
| `RpmsRpc::ParameterEncoder`   | VistA `1{len}00f{value}\x04` parameter encoding  |
| `RpmsRpc::ResponseParser`     | Caret-delimited response parser                  |
| `RpmsRpc::XmlResponseParser`  | VistA RPC XML response parser                    |
| `RpmsRpc::FilemanDateParser`  | FileMan ↔ Ruby Date/Time conversion              |
| `RpmsRpc::PhiSanitizer`       | HIPAA-aligned log/error sanitizer                |
| `RpmsRpc::DataMapper`          | Declarative RPC field/text_blob/scalar mappings  |
| `RpmsRpc::MockClient`          | Hermetic test double with seeded data            |
| `RpmsRpc::MockFhirClient`      | FHIR R4 mock for IRIS for Health reads           |
| `RpmsRpc::SecurityKeys`        | Symbolic ↔ RPMS security key translation         |
| `RpmsRpc::UserRoles`           | Role-based authorization (provider, nurse, etc.) |
| `RpmsRpc::Capabilities`        | Feature-gated permission checks                  |

### Exception-message sanitization

The gem doesn't emit internal logs of its own; the PHI risk vector is
**exception messages** that interpolate raw broker response payloads
(authentication errors, BMX security / application errors, handshake
rejections). Those raise sites pass through `RpmsRpc.sanitize_error`,
which scrubs PHI patterns via `RpmsRpc::PhiSanitizer.sanitize_message`
before the exception propagates to the host.

This is on by default. To opt out — for example, in a local
forensic-capture session where the raw broker payload is what you
need to see:

```ruby
RpmsRpc.configure { |c| c.unsafe_raw_errors = true }
```

Leave this off in production.

## RPC coverage against a backend (the headline number)

The coverage number is measured against **one backend's registry**, not against allowlists
(#270):

```sh
rake rpc:coverage
# RPC coverage: 0.7% (37 / 4960 registered on bcer-9.0-20260930-8c88e47-ydb; 597 excluded) · declared 198 · unregistered names used 0
```

- **Denominator:** every #8994 name on the pinned rpms-ops build
  (`data/inventories/<release-tag>/<release-tag>-broker_8994.txt`, the release's own inventory,
  pinned by `rake conformance:pin`; see [docs/conformance/CAPTURE.md](docs/conformance/CAPTURE.md)),
  minus the names in `data/rpc_coverage/exclusions.yml`. Each exclusion carries a reason from a
  fixed list, and is reviewed like code.
- **Unreachable RPCs are excluded from the pinned build's reach face (#278, #394):** an RPC whose
  routine or entry point is not on the image, that is inactive, that no context lists, or whose
  every context is out of order cannot be called by any client. rpms-ops publishes that class per
  RPC (`<tag>-rpc_reach.txt`), `rake conformance:pin` commits it, and `rake rpc:exclusions`
  regenerates the exclusions from it, recording its path and pinned sha256. Run it after every
  re-pin; a test fails when the committed file is stale against the pinned face. Out-of-order RPCs get their own reason (`context_out_of_order`),
  since a site can put a context back in service. Reviewed reasons (`gui_plumbing`,
  `write_needs_fixture`) survive regeneration.
- **Covered:** a live run against that backend got an answer that was not a broker error.
  Mock-driven unit tests do not count: `MockClient` answers any name it is seeded with.
- **Output:** the one-liner and per-status counts on stdout.
  `coverage/rpc/rpcs.tsv` has every registered RPC, one row each, with its status
  (`covered`, `live_error`, `declared_untested`, `not_declared`, `excluded:<reason>`).
  `coverage/rpc/summary.json` has the same numbers as JSON.
- **Direction, not a gate:** `data/rpc_coverage/config.yml` records `minimum_percent`, the last
  coverage value. The number never fails the task. A drop below it prints a NOTE, and so does a
  rise, together with the value to record. Raise it then, and never lower it.
- **Fails on:** more than `max_unregistered` names that rpms-rpc uses but the registry does not
  register (lower it toward 0, #207), a bad exclusion (unknown reason, unregistered name, or an
  excluded RPC that answered live), a malformed registry, or a sign-on code in the live evidence.

Live evidence for a backend is refreshed with a read-only run of the API catalogue, one broker
connection at a time, which merges into `rpc-coverage/live/<BACKEND>.json` in
[lakeraven/rpms-diffs](https://github.com/lakeraven/rpms-diffs):

```sh
rake rpc:live BACKEND=local-ydb-0930 BROKER_HOST=127.0.0.1 BROKER_PORT=19300 \
  RPMS_ACCESS=... RPMS_VERIFY=... [RPMS_CONTEXT="CIAV VUECENTRIC"]
```

The run merges: a name already in the file stays there, so a name the gem stops calling is never dropped.
After removing RPC names, delete the backend's file and run again to rebuild it.
The headline is measured as the least-privilege PROV123; it is the development default pair, so that run needs `VISTA_RPC_ENV=development`.

The codes are read from the environment and never written. The implementation lives in
`tools/rpc_coverage/`, which is not part of the gem.

Live evidence is specific to one build, so it lives in rpms-diffs rather than in this repo.
Both tasks read and write it in `rpc-coverage/live/` of an rpms-diffs checkout, by default the sibling `../rpms-diffs`.
Set `RPMS_DIFFS_DIR=` (the checkout) or `RPC_EVIDENCE_DIR=` (the directory) to point elsewhere.
`rpc:coverage` fails when the directory or the backend's file is missing, rather than reporting 0%.
After `rpc:live`, commit the JSON in rpms-diffs.

The same report can be browsed in SimpleCov's HTML interface:

```sh
rake rpc:coverage_html
open coverage/rpc/html/index.html
```

It maps RPC coverage onto SimpleCov's terms:

| SimpleCov | RPC coverage |
|---|---|
| a file | one #9.4 package: the RPCs whose name begins with its namespace prefix (`data/inventories/<release-tag>/<release-tag>-packages_9_4.txt`, from the same pinned inventory) |
| a line | one registered RPC, with its status and detail |
| hit | `covered` |
| missed | `live_error`, `declared_untested`, `not_declared` |
| never relevant | `excluded:<reason>` |

So each package's percentage uses the headline's arithmetic, and SimpleCov's total is the headline number.
A registered RPC whose namespace has no #9.4 package is grouped under that namespace and labelled "not a #9.4 package".
On the pinned 0930 registry that is 18 namespaces: AKFR, BEHW, BMQ, BMQG, CIAB, CIAZ, DBTS, DDR, FSC, GMV, the PCMM `SC*` RPCs, VAFC, XDR and XQAL.

## API coverage: public methods proven by a live spec

[ADR 0010](docs/adr/0010-the-consumer-contract.md), assertion 2: every public method is proven by a live spec, and a method without one is not part of the contract.
`rake rpc:api_coverage` reports which methods those are.
It is generated from the code on every run; nothing in it is maintained by hand.

```sh
rake rpc:api_coverage            # summary per module; VERBOSE=1 adds one line per method
# API coverage: 50 / 256 public methods proven by a live spec (19.5%)
#   RpmsRpc::Referral                                 19 /  22
#   RpmsRpc::Problem                                  10 /  14
#   RpmsRpc::Patient                                   7 /  12
#   ...
# unresolved: 21 methods have an RPC name static analysis could not resolve
# unregistered RPCs sent: none
```

- **Public methods:** every public singleton method of a module under `RpmsRpc` whose source is in `lib/rpms_rpc/api/`, nested modules included (`RpmsRpc::BehavioralHealth::Groups`).
  Public helpers mixed in from another module count, because a host can call them.
- **RPCs:** static analysis (Prism) of the method body and of every `lib/rpms_rpc` method it calls, binding the arguments it passes.
  A DataMapper mapping (`DataMapper.x`, `DataMapper[:x]`, or `:x` handed to a helper) resolves through the loaded mapping registry; a `call_rpc*` with a string literal or a String constant resolves to that string.
  An RPC name the analysis cannot bind (a helper whose RPC is its own argument, an expression) is listed under `unresolved`, never guessed.
- **Registered:** each RPC is looked up on the pinned #8994 registry named in `data/rpc_coverage/config.yml`, with its entry point `TAG^ROUTINE`.
- **Live specs:** every `RpmsRpc::Module.method` call site in `test/live/**`.
  The harness runs every live spec as the persona the run names, and a spec cannot declare its own, so a proven method runs as both the least-privilege and the programmer persona.
- **Status:** `proven` when a live spec calls the method, `not_in_contract` when none does.
  This is static: whether the spec passes is `rake test:live`'s answer, per persona.

The JSON (default `coverage/api/methods.json`, `OUT=` to override) is the input for a resource-oriented view of the API:

```json
{
  "schema": 1,
  "registry": "bcer-9.0-20260930-8c88e47-ydb",
  "personas": ["least-privilege", "programmer"],
  "summary": { "proven": 50, "public": 256, "unresolved_methods": 21, "unregistered_rpcs": [],
               "by_module": { "RpmsRpc::Patient": { "proven": 7, "public": 12 } } },
  "methods": [
    {
      "module": "RpmsRpc::Patient",
      "method": "find",
      "arity": 1,
      "params": [{ "name": "dfn", "kind": "req" }],
      "rpcs": [{ "name": "ORWPT SELECT", "registered": true, "entry_point": "SELECT^ORWPT", "reach": "client-callable", "via": "mapping :patient_select" }],
      "unresolved": [],
      "live_specs": ["test/live/patient_live_test.rb:59"],
      "personas": ["least-privilege", "programmer"],
      "status": "proven"
    }
  ]
}
```

| Field | Meaning |
|---|---|
| `module`, `method` | `RpmsRpc::Patient` and `find`: the call is `RpmsRpc::Patient.find` |
| `arity`, `params` | Ruby's `Method#arity` and `#parameters`; `kind` is `req`, `opt`, `rest`, `keyreq`, `key`, `keyrest` or `block` |
| `rpcs[]` | each RPC the method sends: `name`, `registered` on the pinned registry, `entry_point` (`TAG^ROUTINE`, `null` when not registered), `reach` (its class in the pinned build's `rpc_reach.txt`: `client-callable`, `broker-exempt`, `no-context`, ...; `null` when not registered), `via` (`mapping :name` or `literal`) |
| `unresolved[]` | RPC names the analysis could not bind, with where; empty when every send resolved |
| `live_specs[]` | `file:line` of each call in `test/live/` |
| `personas[]` | the personas those specs run as; empty when there are none |
| `status` | `proven` or `not_in_contract` |

The task is offline and reaches no broker. The implementation lives in `tools/api_coverage/`, which is not part of the gem.

## PhiSanitizer secret

`RpmsRpc::PhiSanitizer` uses HMAC-SHA256 to hash patient identifiers
into stable, non-reversible tokens for log lines. Under Rails it
reads the secret from `Rails.application.secret_key_base`. Without
Rails, set the secret explicitly so token hashes stay consistent
across processes:

```ruby
RpmsRpc::PhiSanitizer.secret_key = ENV.fetch("PHI_SANITIZER_SECRET")
```

Leaving the secret unset is acceptable for local development
(falls through to a fixed dev string), but **production deployments
must set it** — otherwise log correlation across restarts and
hosts breaks, and the dev fallback gives operators a false sense
of unique tokens.

## Which broker to use

RPMS has three brokers in front of one RPC registry (`^XWB(8994)`). Any of
them will run any RPC the session's context allows, but they are not
interchangeable: part of an RPC's contract can live in the broker it was
written for. **Call each RPC through the broker, and under the context, its own
client uses** ([ADR 0007](docs/adr/0007-call-each-rpc-through-its-own-broker.md)).

| Broker | Client class | Built for | Use it for |
|---|---|---|---|
| CIA | `RpmsRpc::CiaClient` | The VueCentric chart | Chart RPCs under `CIAV VUECENTRIC` |
| XWB | `RpmsRpc::XwbClient` | CPRS and stock VistA clients | The same chart RPCs on stock VistA, under `OR CPRS GUI CHART` |
| BMX | `RpmsRpc::BmxClient` | IHS's .NET applications | Registration (`AGG`), scheduling (`BSDX`), behavioral health (`AMHG`), referrals (`BMC`), each under its own option |

The wire formats differ too:

- **XWB** — `[XWB]1130` prefix, length-prefixed pack format (XWBTCPM).
- **CIA** — `{CIA}` framing (CIANBLIS).
- **BMX** — `{BMX}LLLLL` prefix, two-stage handshake (the monitor spawns the
  session), and a broker-level error returned with every reply (BMXMON,
  BMXMBRK).

The BMX applications' RPCs can report a failure through BMX's error channel
rather than in the reply. Called over CIA, that failure is not delivered and
the reply reads as a success. Where a backend serves no BMX listener, calling
them over CIA is a deviation: label it, and verify a write by reading it back.

Don't infer the protocol from the port — sites can and do remap.

## Testing

```bash
bundle install
bundle exec rake test
```

The test suite is hermetic — no sockets, no live RPMS.

### Test results, quickly

Run these whenever you want the current picture; there is no report to keep. The hermetic
suite, then the live specs once per persona against a local container of the build you
care about (the broker port published on loopback; `rake test:live` refuses any other host):

```sh
bundle exec rake test
VISTA_RPC_ENV=development BROKER_HOST=127.0.0.1 BROKER_PORT=<port> PERSONA=PROV123 RPMS_ACCESS=... RPMS_VERIFY=... bundle exec rake test:live
BROKER_HOST=127.0.0.1 BROKER_PORT=<port> PERSONA=SYS123 RPMS_ACCESS=... RPMS_VERIFY=... bundle exec rake test:live
bundle exec rake rpc:coverage
```

Each prints its own summary: minitest's `runs, assertions, failures, errors, skips` line, the
live run's skips listed by issue (a live run in which no spec ran fails), and the coverage
headline from the committed live evidence. Any failure exits non-zero.

PROV123 is a debug account, so its run also needs `VISTA_RPC_ENV=development`. `rake rpc:coverage`
reads the live evidence from an `rpms-diffs` checkout beside this repo, or `RPMS_DIFFS_DIR=`.

- **Wire-format tests** construct packet bytes and assert their layout
- **DataMapper tests** verify field/text_blob/scalar round-trip through parse + format
- **MockClient tests** verify seeded data flows through the full fetch chain
- **Gateway tests** (`test/rpms_rpc/gateways/`) exercise domain-specific RPC
  patterns (patient sections, health summary, referral lifecycle) against
  realistic mock data

### MockClient usage

```ruby
require "rpms_rpc"

RpmsRpc.mock! do |m|
  # Field-based mapping (caret-delimited)
  m.seed(:patient_select, "1", { name: "DOE,JOHN", sex: "M", dob: Date.new(1980, 1, 15) })

  # Text blob mapping (raw text)
  m.seed(:section_data, "1", "NAME: DOE,JOHN\nSEX: M\nDOB: 01/15/1980")

  # Scalar mapping (single value)
  m.seed(:section_save, "1", { success: true })

  # Collection (search results with filtering)
  m.seed_collection(:patient_list, [{ dfn: 1, name: "DOE,JOHN" }], filter_field: :name)
end

# Fetch through DataMapper — same API as production
patient = RpmsRpc::DataMapper.patient_select.fetch_one("1")
text = RpmsRpc::DataMapper.section_data.fetch_text("1")
```

`seed()` auto-detects the mapping type (field, text_blob, scalar) and
stores data in the format that `fetch_*` expects.

## Contributing

Per [ADR 0002](docs/adr/0002-verified-routine-policy.md), every
new RPC must be verified against actual M source in the
[CIVITAS FOIA-RPMS](https://github.com/CivicActions/FOIA-RPMS)
repository before merge. PRs adding new RPCs must include the
M source reference and update [docs/rpcs.md](docs/rpcs.md).

## License

MIT. See [MIT-LICENSE](MIT-LICENSE).
