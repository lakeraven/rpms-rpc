# rpms-rpc

Pure Ruby RPC client for VistA / RPMS — speaks the **CIA/XWB**
(port 9100) and **BMX** (port 9200) broker protocols. No Rails
dependency, no Java, just stdlib.

## Status

Pre-1.0. The wire protocol layer is functional and verified against
the FOIA-RPMS routine sources. See [docs/rpcs.md](docs/rpcs.md) for
the audit trail.

## Why a separate gem?

Historically the VistA RPC client lived inside a Rails app
(`rpms_redux`). That made it impossible to reuse from non-Rails
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

### BMX — port 9200

```ruby
require "rpms_rpc/bmx_client"

client = RpmsRpc::BmxClient.new(host: "vista.example.com", port: 9200)
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
| `VISTA_RPC_PORT`     | `9100`/`9200` | Default depends on subclass      |
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

## Components

| File                          | Purpose                                          |
|-------------------------------|--------------------------------------------------|
| `RpmsRpc::Client`             | Abstract base — auth, cipher, socket helpers     |
| `RpmsRpc::CiaClient`          | XWB/CIA wire protocol (port 9100)                |
| `RpmsRpc::BmxClient`          | BMX wire protocol (port 9200)                    |
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

### PhiSanitizer secret

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

## CIA vs BMX

Both protocols call the same RPC registry (`^XWB(8994)`) and the
same M routines. They differ only in wire framing:

- **CIA/XWB** — `[XWB]1130` prefix, length-prefixed pack format,
  used by CPRS / XWBTCPM. Implemented in
  `FOIA-RPMS/Packages/RPC Broker/Routines/XWBTCPM.m`.
- **BMX** — `{BMX}LLLLL` prefix, two-stage handshake (monitor
  spawns session), used by BMXMON. Implemented in
  `FOIA-RPMS/Packages/M Transfer/Routines/BMXMON.m` and
  `BMXMBRK.m`.

Pick the protocol that matches the broker your site is running.
Don't infer protocol from port — sites can and do remap.

## Testing

```bash
bundle install
bundle exec rake test
```

The test suite is hermetic — no sockets, no live RPMS.

- **Wire-format tests** construct packet bytes and assert their layout
- **DataMapper tests** verify field/text_blob/scalar round-trip through parse + format
- **MockClient tests** verify seeded data flows through the full fetch chain
- **Gateway tests** (`test/rpms_rpc/gateways/`) exercise domain-specific RPC
  patterns (patient sections, health summary, referral lifecycle) against
  realistic mock data

### MockClient usage

```ruby
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
