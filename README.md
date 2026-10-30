# rpms-rpc

Pure Ruby RPC client for VistA / RPMS — speaks the **CIA/XWB**
(port 9100) and **BMX** (port 9101) broker protocols. No Rails
dependency, no Java, just stdlib.

## Status

Pre-1.0. The wire protocol layer is functional and verified against
the FOIA-RPMS routine sources. See [docs/rpcs.md](docs/rpcs.md) for
the audit trail.

Patient registration checks AG's name/DOB candidates before adding. See
[registration safety and duplicate overrides](docs/REGISTRATION_SAFETY.md).

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
- **SecurityKeys** — symbolic names for the SECURITY KEYs a built image has; which keys a user holds is `Authentication.held_keys`, and what they allow is the host's decision (ADR 0010)

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

Once signed on, a host can check that the server serves every RPC this release of the gem sends (#366), the way CPRS checks at startup.
It reports by default; `strict: true` raises `RpmsRpc::Compatibility::MissingRpcsError` naming each missing RPC by API module.
Over CIA it reads REMOTE PROCEDURE (#8994) with a paged `DDR LISTER` in the sign-on option, `CIAV VUECENTRIC`; over XWB, one `XWB IS RPC AVAILABLE` per RPC.

```ruby
report = client.compatibility
warn report.to_s unless report.ok?  # report.missing => { "RpmsRpc::Referral" => ["BMC ADD REFERRAL"] }
client.compatibility(strict: true)  # fail at boot instead
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

### A local broker from the pinned release (`bin/cloud_rpms`)

On a machine with Docker and no route to a staging stack (a cloud agent VM, say),
`bin/cloud_rpms up` starts `dockerd` if none is running, then runs lakeraven-ehr's
`compose.yml`, so the run recipe lives in one place. By default it runs the rpms-ops
release marked Latest (the newest that passed the gate); `RPMS_TAG=<release tag>` runs a
specific one, and `PINNED=1` runs the build `data/fingerprints/rpms-ops.lock.yml` records.
When `gh` can't read the Latest release (no access to rpms-ops), it falls back to that
lock pin. Changing release resets the container's synthetic data. It needs a
lakeraven-ehr checkout (`LAKERAVEN_EHR_PATH=`, default `../lakeraven-ehr`) and pull
access to `ghcr.io/lakeraven`. The CIA broker is on `127.0.0.1:9100`; `down` removes the
container and `status` shows its health.

```sh
bin/cloud_rpms up
BROKER_HOST=127.0.0.1 BROKER_PORT=9100 bundle exec rake wire:capture RELEASE=bcer-9.0-ydb
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

### Request size limits (#472)

A request the wire cannot frame is refused before that request is sent, with a `Client::FrameTooLongError` (an `RpmsRpc::Error`):
`XwbClient::LpackTooLongError` for an XWB value over 999 **bytes** (the `[XWB]1130` header fixes the length at 3 digits), and
`BmxClient::RequestTooLongError` for a BMX request over 512 bytes (`BMXMBRK` cuts a request there). The connection stays usable.
CIA has no such limit.

API methods whose contract is a failure hash catch it and answer with that hash plus an `:error` naming the limit (never the value;
`Registration.update`'s byte count is the whole joined window): the visit writes (`ProgressNote.update_text`, `ExamComponent`, `HealthFactor`, `Pov`, `Procedure`,
`ImmunizationRefusal`), `Problem` add/update/delete, `ESignature.remove`, the `Scheduling` writes, `Registration.update`
(`error: :frame_too_long` with `filed_windows:`), `Referral`'s BMC writers and `DdrFileman.filer`. `Referral`'s refusal hash carries
`:error`, where a broker-side failure carries `:message` and `:raw` only, so a caller that branches on `:message` must also check
`:error`. The rest let the error propagate and are not yet audited (#480); `Registration.register` and `Patient.register` raise it.
On a real session an API may already have bound its context before the refused write, which changes no record. A host that creates a record and then updates it (create, then `update_text`) still
holds the first record after a refusal; a pre-check is tracked in #480. `ProgressNote.update_text` wraps a line longer than 80 bytes
(or `wrap_width:`, an Integer from 4 to 999) into `TIUX("TEXT",n,0)` pieces before it is sent (#479), so a line over 999 bytes is sent
on XWB rather than refused, and the chart shows those pieces as separate lines. Rejoining the pieces with the dropped character restores
the line. Joined with a single space, a tab at a cut reads back as a space, and a space or tab cut at the very end of a line is dropped.
Non-whitespace is never dropped or changed. Indentation is not repeated on continuation pieces; an indent wider than the width is itself
hard-cut. Text is coerced with `to_s`, then refused with `{ success: false, raw: nil, error: }` and not sent unless the result is a
String whose encoding is exactly UTF-8, US-ASCII or ASCII-8BIT and whose bytes are valid UTF-8. Any other encoding is refused
regardless of content (a Latin-1 or Windows-1252 tag whose bytes happen to be valid UTF-8 would otherwise be filed as different
characters), as is a `to_s` that returns nil or a non-String. The error does not include the text. `FrameTooLongError` is still rescued
when a wire refuses a framed value: the failure hash says the request could not be framed on this wire, keeps the wire's message, and
never includes the note text. On BMX, `update_text` raises `NotImplementedError` for every note, because `BmxClient#call_rpc` rejects
any list or Hash parameter before framing. That BMX behaviour predates #479 and is unchanged.

### Allergy assessment: never hide an allergy, never vouch for a reply

`RpmsRpc::Allergy.assessment(dfn)` classifies **every line** of the reply as a recognised **marker**, a clean **row**, **blank** (a truly
*empty* segment), or **unrecognised**. This rests on what `LIST^ORQQAL` can emit (`ORQQAL.m:7-16`, with `GMRAOR1.m` `EN1`): exactly three markers
(`^No Allergy Assessment`, `^No Known Allergies`, and `^No allergies found.`, written at line 15 only when no row was written) in
branches that are mutually exclusive with the rows, and every row begins with the allergy IEN, a **positive integer** (`GMRAIEN`,
`Q:GMRAIEN<1`). So a real reply is one marker line **or** rows, never both, and every row's first piece is numeric. Anything else is,
by definition, not a clean reply, and an unknown lookalike can only make the answer louder.

- **Verified absence is strictly byte-exact:** only the exact `^No Known Allergies` line, as the sole data line, is NKA. When the
  reply is a String, the line terminators that splitting it produces (`"...\r\n"`, the real shape) are not part of the marker. When
  it is an Array, an element that still carries a line terminator is not the byte-exact marker: it is a lone marker (not assessed,
  never NKA). Nothing strips record framing (RS/US) first: no client delivers it inside a line of this reply (`XwbClient` splits an
  array reply at CR/LF only; `CiaClient` splits at RS and drops the lone US node; `BmxClient` does not carry a stock RPC), so a
  framing byte glued to the marker, or an element that is only framing beside it, is an unrecognised line, never NKA.
- **A marker** is `^` plus the marker text and nothing else: whitespace, a carriage return, a no-break or invisible character, a
  different case or blank extra fields are tolerated. A marker with any **non-blank** extra field (`^No Known Allergies^LATEX^SEVERE`)
  is **not** a marker: it is unrecognised, and its text is surfaced. A lone marker is `{ assessed: false, nka: false, allergies: [] }`.
- **A clean row** has a first piece that is *exactly* a positive integer (no whitespace or invisible character tolerated), **visible**
  allergen text in piece 2, and no control character anywhere (so RS/US framing and NUL are never stripped into a clean row). ASCII
  controls always count. A real U+0080-U+009F **codepoint** read from UTF-8 (NEL, CSI: a control sequence, not text) makes the row
  unrecognised, but a **byte** 0x80-0x9F in a BINARY string that is not valid UTF-8, or in a Latin-1 / Windows-1252 tagged string, is
  a byte (printable in Windows-1252) and stays a clean row, byte-identical to `main`. Which charset a live site uses is unproven
  (rpms-rpc#476).
  A real row has **at most four pieces** (`IEN^agent[^severity[^signs]]`): a fifth or later non-blank piece makes the line unrecognised
  (surfaced, conflict), so the four-field mapping can never drop text. An allergen whose *text* mentions a marker, on such a row, is
  a normal row.
- **Invisible** means genuinely invisible: zero-width space/joiners (U+200B-U+200D), U+2060-U+2064, U+FEFF, the soft hyphen, U+034F,
  U+180E, tag characters and variation selectors. Other format characters (U+0600-U+0605, U+06DD, U+070F, U+110BD, the bidi marks) are
  visible text, so a line made of one is data. **Only a truly empty segment is blank** (an empty-string element, or what splitting a
  String leaves between two line terminators, e.g. `"marker\r\n"`): a whitespace-only or invisible-only Array element or String
  segment beside the marker is content ORQQAL cannot emit, so it is unrecognised (conflict, never NKA).
- **Every String** (a whole response, or an element of a list) is split into lines first, on CR, LF and (for UTF-8, BINARY and
  US-ASCII text) the UTF-8 *byte sequences* for U+2028, U+2029 and U+0085, **whether or not the rest of the line is valid UTF-8**; a
  lone 0x85 in a single-byte encoding is a character, not a line break. So a marker glued to a row is two lines. A list inside the list is unrecognised **even when empty** (it surfaces as its inspect text,
  e.g. `[]`), and so is an element that is not text (its inspect text is surfaced). Lists nested deeper than 64, or cyclic, raise
  `RpmsRpc::Allergy::ReplyTooDeepError` (an `RpmsRpc::Error`). An element tagged with any encoding other than UTF-8, BINARY,
  US-ASCII or a single-byte ISO-8859-x / Windows-125x tag (UTF-16/32, UTF-7, Shift_JIS, EUC-JP ...) is unrecognised and surfaced
  verbatim: it is never transcoded, and no byte is ever deleted from it. A US-ASCII-tagged string with a high byte is read as BINARY
  (no exception).
- **Bytes.** Classification reads the line's bytes (never transcoded) with invalid bytes made U+FFFD (not deleted, so `^No Known\xFF Allergies` is
  not a marker). **A clean row's output is the original bytes and encoding, as on `main`:** XWB delivers BINARY strings, and a Latin-1
  byte in an allergen name is a clean row (`assessed: true`, no `:conflict`) whose bytes are the boundary's concern (rpms-rpc#477,
  `Reply#altered?`). Only a UTF-8-tagged string that is not valid UTF-8, which `main` raised on, is scrubbed (U+FFFD) before parsing.
- **Anything unrecognised**, **a marker beside other data**, or **a repeated marker** is the signature of a broker desync, a
  concatenated or a corrupted reply: its rows may belong to another call (or patient), or the list may be truncated. The result is
  `{ assessed: false, nka: false, allergies: [...], conflict: true }`: always `assessed: false`, never `nka`. `allergies` holds the
  clean rows plus, for **every unrecognised line with content**, a flagged entry
  `{ ien: nil, allergen: <line, scrubbed and trimmed, for display>, raw: <the line as the reply holds it>, unrecognised: true }`. It is
  never routed through DataMapper's error or no-data filters (which would drop `-3^PENICILLIN` or `^LATEX`) and no piece position is
  guessed. Marker lines and empty segments never become entries; a whitespace-only, invisible-only, control-only or invalid-byte-only line does,
  with `raw` preserving its bytes and `allergen` the scrubbed display copy (possibly empty: rely on `raw` and `unrecognised`).
  `raw` is the line **as the reply holds it**: the original bytes for a plain reply, but the text *after* alteration for a `Reply` or
  `Reply::Text` that altered it (an invalid byte becomes U+FFFD, a control character becomes a space), so an altered marker's `raw`
  can equal the marker text. A host must read `unrecognised`, `altered` and `conflict`, never compare `raw` to a sentinel.
  **Known limit, shared with `main`:** on the CIA line path a control character inside a line (US, NUL, VT, FF, TAB, ESC, DEL; RS is
  safe only because `CiaClient` splits on it) is replaced by a space *before* the classifier runs, so the line it sits in reads as one
  `altered: true` row. That joins a row to a marker (`1^PENICILLIN\x1f^No Known Allergies` is one row with severity `No Known Allergies`,
  never `nka`) and equally folds a second allergy into the first row's fields (`1^PENICILLIN\x1f2^LATEX` is one row with allergen
  `PENICILLIN 2` and severity `LATEX`), where the same lines in a plain Array are conflicts. `main` returns the identical row without the
  `altered` flag. ORQQAL writes one row or one marker per node (`CIANBACT.m` `OUT`, `ORQQAL.m` `LIST`), so a mid-line control byte can
  only come from a control byte stored inside a GMRA field.
  If the parser ever returned fewer rows than it was given, the reply is a conflict, never `assessed`. A **false**
  conflict is loud and safe, never a false "no known allergies".
- **Clean replies are unchanged** (byte-identical to `main`, including encodings, except that a line terminator inside an Array
  element is split off instead of kept, e.g. `["7^LATEX^MODERATE\n"]` gives severity `MODERATE`) and carry no `:conflict` key and no `:unrecognised`
  key.

**What a host must do.** A host that reads only `:nka` and `:assessed` is safe in the absence direction ("None recorded" cannot appear
beside a real allergy, and a conflicting reply never reads as assessed). **A host that must show a conflicting list as incomplete must
read `:conflict`.** `Allergy.for_patient` returns the allergy entries only, so it returns the surfaced entries of a conflicting reply
too and cannot tell a verified list from a conflicting one: a host that must make that distinction **must use `Allergy.assessment`**
and read `:assessed` and `:conflict`. **Host-visible changes:** a host that renders rows from `for_patient` will now show the text of
an unrecognised line (for example `-3^PENICILLIN^SEVERE^HIVES`) as an entry with a `nil` `:ien`; that is intended. Because those
entries have no IEN, a host that builds identifiers from the allergen text can collide on them, and nothing in the entry marks the
resulting FHIR resource unconfirmed: the host must read `:unrecognised` / `:conflict` (lakeraven-ehr#672). The patient banner does not
read `:conflict` yet (`AllergyListStatus.from_counts` shows any rows as a loaded list; also #672).
Unproven live (ADR 0009): this is decided from the M routine source; the routine cannot produce a conflicting reply.

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

### Reply encoding

Every reply `call_rpc` returns, on XWB, BMX, CIA and `MockClient`, is an
`RpmsRpc::Reply`: an `Array` of **UTF-8, `valid_encoding?`** Strings, so
`first`, `map`, `join` and indexing work as before and joining a line with a
UTF-8 literal no longer raises `Encoding::CompatibilityError`.

Bytes that are not valid UTF-8 are replaced with U+FFFD, and the reply says
so:

```ruby
reply = client.call_rpc("ORQQAL LIST", dfn)
reply.altered?        # => true when any line had to be altered
reply.altered_lines   # => zero-based indexes of those lines
RpmsRpc::Reply.altered?(x)  # false for anything that is not an altered Reply
```

**Charset: assumed UTF-8, UNPROVEN.** Latin-1 is observed in stored data
(`conformance/build_surface.rb`, the `\xB7` bullet in the `bcer-9.0-20260930`
RPC descriptions; `api/patient.rb` notes non-UTF-8 name bytes), so real
Latin-1 text is replaced and reported as altered. No site or broker character
set is documented in this repository; a live read with a known high byte is the
follow-up that settles it.

Altered text must never read as verified identity: a host that matches on reply
text (an allergen name, a patient name) must check `altered?` and refuse an
altered line.

**What reaches a host, and where the flag lives**

- `RpmsRpc::Allergy.assessment` / `.for_patient` and `RpmsRpc::Patient.lookup`
  put `altered: true|false` on **every clean row** they return. It is true when
  any text of that row had a byte replaced. Two allergens that differ only in a
  byte the gem replaced read identically, and each says `altered: true`: refuse
  them. The key is additive; no existing key changed.
- A surfaced **unrecognised** entry (`unrecognised: true`, in a `conflict: true`
  reply) carries `altered: true` only when it was altered, and has no `altered`
  key otherwise. A missing key there means "not altered", never "clean": the
  entry is unrecognised, and the reply is a conflict, whatever the key says.
- A reply that arrives as one blob (a CIA `call_rpc_global_array` read, a bare
  String seed in `MockClient`) is an `RpmsRpc::Reply::Text`: a valid-UTF-8
  **String** that answers `altered?`. `RpmsRpc::Reply.altered?(x)` is the safe
  check for either kind.
- A `Reply` and its lines are **frozen** and a `Reply` is built only through
  `Reply.from_wire`. `shift`, `<<` and `clear` raise, because they would leave
  `altered_lines` pointing at the wrong line. `Reply.from_wire(reply)` keeps the
  alterations the reply already carries.
- Every non-mutating transform returns a plain `Array`/`String` and drops the
  flag: `map`, `select`, `reject`, `+`, `-`, `&`, `|`, `*`, `[]`, `slice`,
  `first`, `last`, `take`, `drop`, `reverse`, `rotate`, `sort`, `sort_by`, `uniq`,
  `compact`, `flatten`, `zip`, `each_slice`, and `String#split`. Ask the reply
  first, or carry `RpmsRpc::Reply.altered?(reply)` forward yourself.
  Coercing a `Reply::Text` (`to_s`, `slice`, `+`) likewise yields a plain `String`, which cannot carry a flag, so a control-altered
  Text coerced to a String reads clean; ask the Text first.
- Other API modules that return identity-bearing text (names, identifiers) go
  through `DataMapper` and do **not** yet carry the flag; the follow-up issue
  lists them. Until then, call `client.call_rpc_lines` and check the reply
  yourself before trusting their text.

On CIA, control characters (and DEL) in a line have always become a space; they
still do, and that is now reported as altered too. Valid non-ASCII text is no
longer turned into spaces.

## RPC coverage against a backend (the headline number)

The coverage number is measured against **one backend's registry**, not against allowlists
(#270):

```sh
rake rpc:coverage
# RPC coverage: 0.7% (37 / 4961 registered on bcer-9.0-20261012-e7923a4-ydb; 596 excluded) · declared 197 · unregistered names used 0
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
- **"Not in FOIA" is not "not real"; registration is the test (rpms-ops `docs/CLIENTS.md`).** FOIA is a
  partial public copy of what IHS distributes. On bcer-8.3, 550 registered RPCs had backing routines absent
  from the FOIA *source tree*, and every one was legitimate IHS: most from packages registered in `#9.4`
  whose source IHS does not publish (Clinical Reporting BGP, imaging MAG, dental ADE, BPC), the rest from IHS
  namespaces with no `#9.4` row (AKFR, BMQ). The *built image* closes much of that gap, since KIDS installs
  routines FOIA lacks: `bcer-9.0-20261020-f28336e-iris` marks 203 RPCs `no-routine` and 95 `no-entry-point`
  in its reach face. So: never drop or "fix" a mapping because its routine is missing from FOIA; check the
  pinned registry and reach face, and treat a name registered nowhere (no `#8994` row on any captured
  build) as the only sign of an invented RPC. Every invented name found so far was client-side.
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
  "registry": "bcer-9.0-20261012-e7923a4-ydb",
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

## Order checks

`RpmsRpc::Order.check` runs order checks through `ORWDXC ACCEPT` before an order is saved (#454). Each row is `ORID^checkIEN^CDL^text`. A high or unknown severity requires an override. An empty or unparseable reply is reported as order checks unavailable.

The incomplete-checks memory follows the client object, so a host must reuse one client object per broker connection. A fresh wrapper per request around a shared connection loses it, and OPOS then hides the banner (ORWDXC.m:53,214-229). The memo is an `ObjectSpace::WeakKeyMap`: keys are compared with `eql?` and `hash`, not strict object identity.

## Scheduling list reads

`Scheduling.availability`, `all_appointments`, `hospital_locations`, `clinic_setup`, `resources`, `slot_schedule` and `appointments` raise `RpmsRpc::Client::RpcError` when a BSDX list read fails (#481). Hosts must rescue it. A header-only recordset, including a header behind leading spaces, U+FFFD or C0 control characters, is still a genuine empty result (`[]`). That flattened or junk-prefixed shape is handled defensively; no current client is known to produce it. `CiaClient#parse_cia_reply` strips the sequence echo and the `\x00` ack before `Reply.from_wire`, so `call_rpc` does not flatten them into that prefix.

An error row or a blank line behind that prefix is classified like a plain one: the error raises with its numeric code, and a reply of only blank-after-strip lines raises. `resources`, `slot_schedule` and `appointments` parse the classified lines, so a flattened header maps columns the same way as an unflattened one, and a reply with no header row raises (`no recordset header`) whether or not it is framed. The other four list reads still accept an unframed headerless line list whose every non-blank line contains a caret; a non-blank line with no caret raises (`no recordset header`). An ERRORID header line anywhere raises (`ERRORID recordset`); more than one header line otherwise raises (`unexpected second header`). Both paths do. Before any regex, each String chunk is brought to UTF-8: a chunk that is not UTF-8-tagged is duplicated and force-encoded UTF-8, and bytes that are not valid UTF-8 raise (`reply is not valid UTF-8`). A valid binary-tagged reply parses with UTF-8 values.

The message names the RPC and, for a `-N^` row, the numeric code (`broker error -1`), or a fixed phrase (`ERRORID recordset`, `empty reply`, `no recordset header`, `unexpected second header`, `reply is not valid UTF-8`, `unexpected reply type`). Broker text stays out of the message: it can hold a patient name, and `sanitize_error` does not catch mixed-case names. The failure is never `Encoding::CompatibilityError`. `DataMapper#fetch_many` and `#fetch_many_or_nil` on these mappings keep the old contract for direct mapper callers. Only the Scheduling methods changed.

## Retry safety

The gem never retries. `RpmsRpc::RetrySafety` and `lib/rpms_rpc/retry_safety.yml` classify each public method as `read`, `idempotent_write`, or `non_idempotent_write`, as advice to hosts. Only `:read` is `auto_retry_safe?`. An unclassified method is never retry-safe. `bundle exec rake rpc:retry_safety` fails when a public method is unclassified or an entry is stale.

## OpenAPI documents: the RPC surface and the client API

rpms-rpc generates two OpenAPI 3.1 documents (#395), and every GitHub release of the gem carries them as assets (`.github/workflows/openapi-release.yml`).

```sh
rake openapi:pin RELEASE=<tag>  # pin that rpms-ops release's <tag>-rpcs.json (data/openapi/)
rake openapi:surface   # pkg/openapi/rpc-surface.openapi.json: every RPC the pinned build registers, addressed as a resource
rake openapi:api       # pkg/openapi/client-api.openapi.json: the gem's public methods, each with the RPCs behind it
rake openapi           # both
```

The surface reads one rpms-ops file, the pinned build's `<tag>-rpcs.json` (rpms-ops#732), through `BuildSurface`, after proving its sha256 and validating it against the schema it names (rpcs.v1 or rpcs.v2); the client API is `rake rpc:api_coverage`'s analysis.
Both name the gem commit and the build tag, are byte-identical for the same inputs, and fail unless they are valid OpenAPI 3.1 with every verb and path unique.
[docs/openapi.md](docs/openapi.md) defines every `x-rpms` field, the addressing rules and how to fetch the documents from a release.

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

`bundle exec rake report:daily` runs the hermetic suite, then the live specs once per persona, prints a summary, and writes one markdown file. It exits non-zero when a suite fails, errors, or its summary cannot be parsed.

Point it at a broker in either of two ways.

- **An already-running broker.** Set `BROKER_HOST` and `BROKER_PORT` (a loopback address; `rake test:live` refuses any other host). `BUILD`, when set, is the build under test; otherwise the build is the tag of the Docker image that publishes that port.
- **A fresh container of the newest `bcer-*-ydb` release.** `FRESH=1` starts that release's image with the broker published on a free `127.0.0.1` port, waits until the CIA connect answers, runs the suites, and removes the container when it finishes, including after a suite failure or a connect timeout. `FRESH=1 DRY_RUN=1` prints the plan and leaves Docker and the suites untouched.

The report process reads sign-on codes from `PROV123_ACCESS`, `PROV123_VERIFY`, `SYS123_ACCESS`, and `SYS123_VERIFY`. Each persona's pair is placed in `RPMS_ACCESS` and `RPMS_VERIFY` only inside that persona's `rake test:live` child, with `PERSONA` and the broker host and port. PROV123 is a debug account, so that child also gets `VISTA_RPC_ENV=development`. A missing or blank pair skips that live run, records `missing PROV123_ACCESS/PROV123_VERIFY` (or the SYS123 names), and exits non-zero. The codes stay in that child environment. The printed summary, the report, the plan, and the command line carry the variable names only.

The file is `<rpms-diffs>/rpc-coverage/daily/<date>-<build>.md`. `rpms-diffs` is the checkout beside this repo, or `RPMS_DIFFS_DIR`. The command stops before the suites when `rpc-coverage/daily` is missing. When `rake rpc:coverage` can run, its headline is included. When it cannot, the report says why. `rake rpc:coverage` reads the live evidence from an `rpms-diffs` checkout beside this repo, or `RPMS_DIFFS_DIR`.

The same checks can still be run one at a time:

```sh
bundle exec rake report:daily
FRESH=1 DRY_RUN=1 bundle exec rake report:daily
FRESH=1 PROV123_ACCESS=... PROV123_VERIFY=... SYS123_ACCESS=... SYS123_VERIFY=... bundle exec rake report:daily

bundle exec rake test
VISTA_RPC_ENV=development BROKER_HOST=127.0.0.1 BROKER_PORT=<port> PERSONA=PROV123 RPMS_ACCESS=... RPMS_VERIFY=... bundle exec rake test:live
BROKER_HOST=127.0.0.1 BROKER_PORT=<port> PERSONA=SYS123 RPMS_ACCESS=... RPMS_VERIFY=... bundle exec rake test:live
bundle exec rake rpc:coverage
```

Each of those prints its own summary: minitest's `runs, assertions, failures, errors, skips` line, the live run's skips listed by issue (a live run in which no spec ran fails), and the coverage headline. Any failure exits non-zero.

- **Wire-format tests** construct packet bytes and assert their layout
- **DataMapper tests** verify field/text_blob/scalar round-trip through parse + format
- **MockClient tests** verify seeded data flows through the full fetch chain
- **Gateway tests** (`test/rpms_rpc/gateways/`) exercise domain-specific RPC
  patterns (patient sections, health summary, referral lifecycle) against
  realistic mock data

### Releasing

`rake release` refuses to tag or push unless the live summaries in `coverage/live/` prove a green run of exactly what it is about to ship (#361, #441).
Each summary is schema 3. It names the pinned build it ran against, the source it tested, and the suite it ran, and records `passed`.
The source is a SHA-256 over every file the gemspec ships, plus the gemspec, read from the working tree.
The suite is a SHA-256 over every file under `test/live/` plus `data/rpc_coverage/config.yml`, so a change to the specs or the pin is a different suite.
`passed` is true only when every non-skipped result passed.
`CHANGELOG.md` is not shipped, so the release section can quote the live summary without invalidating the source fingerprint.
Anything that is shipped does invalidate the source, including the version bump and a README edit. A change under `test/live/` or to the coverage pin invalidates the suite.

So the order is: bump the version and finish every shipped file and the live specs, then `rake test:live` once per persona, then `rake release`.
A run during which a shipped file or the live suite changes is not recorded.
A summary from before schema 3, or for another build, source, or suite, or with `passed` other than true, is refused until `rake test:live` is re-run for that persona. Delete the file if that persona is not part of the release.

The policy on top of that: a CIA summary is required (`<persona>.json`); BMX and XWB summaries are optional, but any that is on disk must be green. A summary must have run against the pinned build (`build_source` is `pinned`), so a run that set `LIVE_BUILD` is refused. A file that skipped more than 10% of its runs is refused. The guard's OK line names the directory it read.

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
