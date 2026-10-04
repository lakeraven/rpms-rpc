# Transport security: wrapping the broker connection in TLS

rpms-rpc speaks the XWB, BMX and CIA broker protocols over **plain TCP**. Every
byte is plaintext on the wire. That includes the access/verify codes at
sign-on, every RPC parameter, and every reply, which carry PHI.
The gem does not ship TLS and will not.
Put the TLS around the connection when you deploy, with one of the patterns
below.

## Why there is no native TLS

- **The brokers have no TLS upgrade.** XWB (`XWBTCPM`), BMX and the CIA
  broker (`CIANBLIS`) read framed bytes from a plain socket. None of them
  negotiates TLS, so a TLS-speaking client would only talk to a broker that
  no RPMS or VistA site runs.
- **Inventing one would fork the protocol.** A gem-specific TLS handshake
  would need a matching server-side change on every broker. That is a burden
  on every site, and it is the kind of change to stock RPMS code this project
  avoids.
- **The sign-on "encryption" is not encryption.** The access;verify pair goes
  through the Kernel XWB cipher (`$$ENCRYP^XUSRB1`, `RpmsRpc::XwbCipher`).
  That is a fixed substitution table published in the source. Anyone who
  can see the bytes can reverse it.

So TLS belongs to the deployment, not the client.
Point the client at a local plaintext endpoint you control, and let a tunnel
carry the bytes to the broker.

## Which pattern to use

The deployment modes follow
[corvid ADR 0006](https://github.com/lakeraven/corvid/blob/main/docs/adr/0006-rpms-deployment-topology.md).
That ADR makes the customer-side connector (Mode 3) the production target and
keeps single-tenant direct (Mode 1) for pilots and development.
It also says corvid does not build multi-tenant inbound (Mode 2).
Mode 2 is still described here because other consumers of this gem may need it.

| Mode | Shape | Transport protection |
|---|---|---|
| 1, single-tenant direct | the app and the broker on one private network | private network only, or an SSM/SSH port forward |
| 2, inbound to the customer network | a hosted app reaches into each customer's network | stunnel at both ends, or a WireGuard/IPsec tunnel |
| 3, customer-side connector (recommended) | a small process inside the customer network runs rpms-rpc next to the broker | the broker hop stays on the customer LAN; the connector dials **out** over mTLS |

### Mode 1: private network, or a port forward

The simplest safe deployment never lets broker traffic leave a private network.
The app and the broker share a VPC or LAN, and the broker ports (9100, 9101,
9200) are open only to the app hosts.

From a workstation, reach a broker through a port forward instead of opening
its port. For example:

```sh
# AWS Systems Manager: no inbound port on the broker host at all
aws ssm start-session --target i-0123456789abcdef0 \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["9100"],"localPortNumber":["9100"]}'

# SSH
ssh -N -L 9100:127.0.0.1:9100 operator@rpms.example.internal
```

Then connect the client to the local end:

```ruby
client = RpmsRpc::CiaClient.new(host: "127.0.0.1", port: 9100)
```

### Mode 2: stunnel at both ends

Run stunnel on the app host in client mode and on the RPMS side in server
mode, with mutual TLS:

```
rpms-rpc -> 127.0.0.1:9100 (plaintext, loopback)
         -> stunnel (app side) == mutual TLS ==> stunnel (RPMS side) :9443
         -> 127.0.0.1:9100 broker (plaintext, on the broker host)
```

The two sample configs are:

- [`tls/stunnel-app-side.conf`](tls/stunnel-app-side.conf), for the host where rpms-rpc runs
- [`tls/stunnel-rpms-side.conf`](tls/stunnel-rpms-side.conf), for the broker host or a host beside it

What the samples insist on, and why:

- **Mutual certificates.** The RPMS side has `requireCert = yes` and
  `verifyChain = yes`, so only hosts holding a certificate from your app CA
  reach the broker at all. The broker's own sign-on is the second gate, not
  the first.
- **Server identity.** The app side has `verifyChain = yes` and `checkHost`.
  A certificate from the right CA for the wrong host is refused.
- **A TLS floor.** Both sides set `sslVersionMin = TLSv1.2`.
- **A loopback plaintext end.** The app side accepts on `127.0.0.1` only.
  The broker port on the RPMS side stays closed to everything but the local
  stunnel.

Add one stunnel section per broker port you use. The defaults are XWB 9100,
BMX 9101 and CIA 9200, and a YottaDB stack serves CIA on 9100.

These samples are tested, not only shown.
`test/rpms_rpc/stunnel_sample_test.rb` runs both files as written, with only
paths, ports and the connect host replaced. It runs them against a throwaway CA
and a fake CIA broker, and checks three things:

- `CiaClient` connects and calls an RPC through the tunnel.
- A plaintext client is refused at the TLS port.
- A TLS client without a certificate is refused.

CI installs stunnel so the test runs on every pull request.

### Mode 2 alternative: WireGuard or IPsec

A network-layer tunnel protects every port at once and needs no per-port
config.
Examples are WireGuard between the hosting VPC and a gateway in the customer
network, or a site-to-site IPsec VPN.
The broker then looks like any private-network host (Mode 1), and the client
connects to its tunnel address.
Restrict the tunnel's allowed IPs and the broker host's firewall to the app
hosts. A tunnel that routes a whole subnet exposes every broker port on it.

At sites whose perimeter firewall is managed centrally, an inbound tunnel of
either kind needs approval from whoever owns that firewall, at every site.
That cost is why corvid ADR 0006 prefers Mode 3.

### Mode 3: a customer-side connector

A small process runs **inside** the customer network, next to the broker:

```
hosted app <== outbound mTLS (443) == connector [rpms-rpc] -> broker (customer LAN)
```

- The connector uses rpms-rpc to talk to the broker over the customer's own
  network. That hop is plaintext but never leaves the customer LAN; keep it
  on a segment that only the connector and the broker share.
- The connector opens an **outbound** mutually authenticated TLS connection
  to the hosted service, so the customer firewall needs only egress.
- Broker credentials live in the connector's local configuration and never
  leave the customer network.

The connector's protocol (envelope, heartbeat, reconnect) is the hosting
application's design (corvid ADR 0006, decision 2), not this gem's.
From rpms-rpc's side, the connector is an ordinary Mode 1 client.

## What PhiSanitizer does not do

`RpmsRpc::PhiSanitizer` and `RpmsRpc.sanitize_error` scrub identifiers out of
**log lines and exception messages** this process writes.
They do nothing for the bytes on the socket.
A broker connection carries names, dates of birth, identifiers and clinical
text in every reply, whatever the logs say.
On any network you do not fully control, use one of the patterns above.
