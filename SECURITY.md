# Security Policy

## Reporting a vulnerability

Lakeraven builds software used in healthcare settings. If you discover a
security vulnerability, please report it privately — **do not open a public
issue or pull request.**

Email **eng@lakeraven.com** with:

- a description of the issue and its impact,
- steps to reproduce (a proof-of-concept if available),
- the affected version, commit, or deployment.

You will receive an acknowledgement within **3 business days**, and we aim to
provide a remediation timeline within **10 business days**. Please give us a
reasonable opportunity to remediate before any public disclosure.

## Scope

This policy covers the source code in this repository. Reports involving a
specific production deployment should also be directed to that deployment's
operator, since a deployment may hold configuration or data that is not part
of this repository.

## Transport security

The broker protocols this gem speaks (XWB, BMX and CIA) are **plaintext TCP**.
Access/verify codes, RPC parameters and PHI-bearing replies all cross the
socket unencrypted.
The XWB cipher applied to the access/verify codes is a published substitution
table, not encryption.
The gem does not provide TLS. The brokers have no TLS upgrade to negotiate.

Reach a broker only over a network you control:

- a private network shared only by the app hosts and the broker,
- an SSM or SSH port forward,
- stunnel at both ends with mutual TLS, or a WireGuard/IPsec tunnel, or
- a customer-side connector that runs the gem next to the broker and dials out
  over mTLS.

[`docs/tls.md`](docs/tls.md) describes each pattern, with tested sample stunnel
configs.
`PhiSanitizer` scrubs logs and exception messages only and does not protect
data on the wire.

## Supported versions

Security fixes are applied to the latest released version on the default
branch. Older versions are supported at Lakeraven's discretion.
