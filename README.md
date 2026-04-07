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

This gem extracts just the wire layer:

- Connection lifecycle (`connect`, `disconnect`, `connected?`)
- Authentication (`XUS SIGNON SETUP`, `XUS AV CODE`, cipher encrypt)
- Application context (`XWB CREATE CONTEXT`)
- Parameter encoding for the VistA `1{len}00f{value}\x04` format
- Caret-delimited and XML response parsing
- FileMan date conversions
- HIPAA-aligned PHI sanitizer for log lines

What it does **not** include: ActiveRecord models, FHIR clients,
domain-specific RPC wrappers, or an adapter contract. Those live
in consumers (e.g. `lakeraven-ehr`).

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
client.authenticate("PROV123", "PROV123!!")
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
| `RPMS_ACCESS_CODE`   | `PROV123`   | Default access code (dev only)     |
| `RPMS_VERIFY_CODE`   | `PROV123!!` | Default verify code (dev only)     |

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

The test suite is hermetic — no sockets, no live RPMS. Wire-format
tests construct packet bytes and assert their layout.

## Contributing

Per [ADR 0002](docs/adr/0002-verified-routine-policy.md), every
new RPC must be verified against actual M source in the
[CIVITAS FOIA-RPMS](https://github.com/CivicActions/FOIA-RPMS)
repository before merge. PRs adding new RPCs must include the
M source reference and update [docs/rpcs.md](docs/rpcs.md).

## License

MIT. See [MIT-LICENSE](MIT-LICENSE).
