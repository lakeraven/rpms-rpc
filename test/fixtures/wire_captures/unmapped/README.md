# Unmapped wire captures

Verbatim broker replies for RPCs that rpms-rpc does not map yet. They are the
evidence a spec author writes a mapping's feature files and failing tests
against, so the first wire shape an implementer meets is a captured one and
not a belief (docs/WIRE_CONTRACTS.md).

They sit in this subdirectory because the wire-contract gate
(`test/rpms_rpc/wire_contract_test.rb`) loads only `../*.yml`, and every file
there must name a registered `DataMapper` mapping and cite its piece
semantics. These files claim neither: no mapping, no piece annotations. They
claim only what was sent and what came back.

## What each file holds

One YAML file per RPC:

| key | meaning |
| --- | --- |
| `rpc`, `entry_point` | the RPC and the `TAG^ROUTINE` the pinned build registers for it |
| `release_tag`, `image` | the rpms-ops release and the image, by digest, the broker ran from |
| `client` | the rpms-rpc client and commit that made the calls |
| `captured_at` | UTC time of the capture run |
| `note` | anything the replies do not say for themselves |
| `captures[]` | one entry per call: `inputs`, `context` (what the synthetic inputs point at), `ack` (`data`, or `error` when the CIA ack byte is `\x01`), `raw_return`, `sha256` |

`raw_return` is the reply exactly as `CiaClient#call_rpc_raw` returned it,
CIA framing included, sealed by `sha256`. Do not edit it; re-capture instead.
`test/rpms_rpc/unmapped_wire_captures_test.rb` checks the seal, the ack label,
and that each RPC and entry point are what the pinned build registers.

## Where they came from

A container started fresh from the pinned release image with rpms-ops
`make fresh-up TAG=<tag> IMAGE=<image@digest>`, signed on as the build's
staging operator, and called read-only with the synthetic patients and notes
that image ships. No customer instance and no write RPC was involved.

## Promoting a capture

When a mapping for one of these RPCs lands, add a `CATALOG` entry for it in
`lib/rpms_rpc/wire_capture.rb` (inputs, cite, pieces), re-capture it with
`rake wire:capture` against a fresh container of the pinned release, and
compare with `rake wire:compare`. The gated fixture then lives in
`../<rpc>.yml`; delete the file here in the same change.
