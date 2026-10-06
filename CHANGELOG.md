# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Deprecated — `RpmsRpc::FhirClient` and `RpmsRpc.fhir_client` (#360)

- Both warn on every call: a FHIR client is host knowledge (ADR 0010, assertion 7) and leaves
  the gem in a later release. They still behave as before. A host that uses them should carry
  its own copy before then.

### Added — live specs over XWB (#236)

- `BROKER_PROTOCOL=xwb rake test:live` signs on with `XwbClient#authenticate` and runs the specs
  in `test/live/xwb/`; the default (`cia`) runs `test/live/*_test.rb` as before. A spec declares
  its broker line (`broker :xwb`) and fails, naming the setting, when loaded under the other;
  `connect_only!` leaves the session for the spec to sign on itself. `LIVE_BUILD` names a target
  that is not the pinned build in the run summary.
- `test/live/xwb/authenticate_live_test.rb` proves `Authentication.authenticate` end to end:
  DUZ, `post_signon_message_count` against the XUS AV CODE reply, and `user_type` against a
  direct ORWU USERINFO read in the same session. A non-programmer's XWB session cannot run
  ORWU USERINFO at that point, so its `user_type` is the fail-closed error until #393.

### Added — one base class for every error the gem raises (#357)

- `RpmsRpc::Error < StandardError` is the base of every exception class in `lib/`: a host
  rescues it in one place and tells the failures apart by subclass. Class names and the
  relationships between them are unchanged (`CredentialError < AuthenticationError`,
  `RpcTimeoutError < TimeoutError < ConnectionError`, `RpcNotAvailableError` and
  `RpcRefusedError < RpcError`), so existing rescues keep working. `ArgumentError` and
  `NotImplementedError` for caller misuse stay as they are.

### Fixed — `Problem.edit_load` sends the three formals of EDLOAD^ORQQPL1 (#364)

- `Problem.edit_load(ien, provider_duz:, institution_ien:)` sends the problem IEN, the provider
  DUZ and the facility (an INSTITUTION #4 IEN), the formals `EDLOAD(RETURN,DA,GMPROV,GMPVAMC)`
  declares (ORQQPL1.m:83). The IEN-only frame died in M on GMPVAMC (GETFLDS+20^GMPLEDT3).
  **Breaking:** the two keywords are required.

### Fixed — `Patient.search`, `find_by_ssn` and `:patient_list` match what ORWPT answers (#352)

- `Patient.find_by_ssn` strips punctuation before ORWPT FULLSSN, which matches the SSN index
  exactly: `"000-00-9999"` now finds the patient `"000009999"` finds.
- `Patient.search` starts its ORWPT LIST ALL page just before the text, so a search by the exact
  name lists that patient first. It is documented as one page (44 rows at most) of the name
  index from the text on, not a filter.
- **Breaking:** `:patient_list` no longer maps `:sex` and `:dob`. ORWPT LIST ALL rows are
  `DFN^NAME^^^^NAME`; both were always nil against a server.

### Added — the conformance gate requires every RPC the gem sends to be callable on the pinned build (#394)

- `rake conformance:pin` now pins the release's reach face (`<tag>-rpc_reach.txt`) and RPC
  signatures (`<tag>-rpc_signatures.txt`) with the registry, checksum-verified against the
  sidecar, the release's asset digests and the provenance's `rpc_reach` / `rpc_signatures`
  faces, and records the image digest and reach class counts in the lock. A release published
  before rpms-ops#713 has no reach face and cannot be pinned until re-gated.
- `bcer-9.0-20260930-8c88e47-ydb` re-pinned after rpms-ops#740 backfilled its inventory: new
  provenance and sidecar, two new assets; the registry and package bytes are unchanged.
- `RpmsRpc::Conformance::BuildSurface` is the one reader of the pinned files (registry, reach,
  signatures, packages). The names gate, the new callable gate, `rpc:exclusions`, `rpc:coverage`,
  `rpc:api_coverage` and the pin all read through it; it is the seam the OpenAPI generator (#395)
  and rpms-ops's structured `<tag>-rpcs.json` (rpms-ops#732) plug into.
- `test/rpms_rpc/callable_rpc_names_test.rb` fails on any RPC a public method sends whose reach
  class is not `client-callable` or `broker-exempt`, naming the RPC, the class and the methods.
  On this pin two are build defects, recorded with their issues in
  `data/fingerprints/uncallable_exceptions.yml` and printed on every run: `DDR KEY VALIDATOR`
  (no-entry-point, rpms-ops#720) and `VAFC VOA ADD PATIENT` (no-context in the published image,
  rpms-ops#737/#740).
- `rake rpc:api_coverage` reports each RPC's `reach` beside its `entry_point`.

### Changed — `rake rpc:exclusions` reads the pinned reach face, not a local RPC atlas (#394)

- No `ATLAS=`: the unreachable exclusions are generated from the pinned build's reach face.
  On 0930: 597 exclusions (was 598 from the 0921 atlas). `BGOVIMM6 DUPALLOW` and `BMX CVC` are
  callable on 0930 and leave; `VAFC VOA ADD PATIENT` is no-context in the published face and
  joins. Coverage: 37 / 4960.
### Added — `rake rpc:api_coverage`: public methods proven by a live spec (#358)

- Lists every public method of the API modules with the RPCs it sends (resolved statically
  through DataMapper mappings and `call_rpc*` literals and constants), whether each is on the
  pinned registry, and the live specs that call it. A method no live spec calls is reported as
  not in the contract (ADR 0010, assertion 2).
- Prints methods proven / public methods, per module, and writes `coverage/api/methods.json`
  (`OUT=` to override); the schema is in the README. On main today: 50 / 256.

### Changed — Ruby 4.0 readiness (#47)

- CI runs the suite on Ruby 3.4 and 4.0.
- `bigdecimal` is now a declared runtime dependency. `lib/` requires it, and it
  has been a bundled gem (not a default gem) since Ruby 3.4. Under Bundler it
  only loaded because a development dependency happened to pull it in.
- No test uses `minitest/mock`, which is not part of Minitest 6. The two `stub`
  calls are now dependency injection: `Client#connect_tcp` is the overridable
  TCP connect.
- `bin/console` works on Ruby 4.0. `irb` is no longer a default gem there, so the
  Gemfile declares it, and the console loads it only after its environment checks pass.

### Deprecated — seven `Capabilities` checks that test names which are not security keys (#314)

- `can_approve_chs?`, `can_process_chs?`, `can_manage_chs?`, `can_manage_consults?`,
  `can_verify_eligibility?`, `can_access_behavioral_health?` and `can_access_dental?`
  each warn once per process. Their answers, the `capabilities_for` entries they feed
  and the `UserRoles.resolve` elevation on `:prc_supervisor`/`:prc_manager` are unchanged.
  No signed-on user can hold the names they test, so on a real session they answer false.
  Replacement: read the keys a user holds (#318) and decide policy in the host (ADR 0010).
  Removal is #359.

### Changed — `SecurityKeys::REGISTRY` names only keys on the pinned build (#314)

- Removed the twelve names that are not SECURITY KEYs (#19.1) on the bcer-9.0 0930 image.
  `symbolize` never returned them for a real session; `MockClient#seed_user` now drops them too.

## [0.3.1]

### Fixed — CIA frame terminator no longer collides with an L() length prefix (#241)

- The `{CIA}` frame terminator moved from `\x1e` to `\x7f` (DEL). The client
  declares the terminator as frame header byte 6 and the broker adopts it
  (`CIA("EOD")=$A(X,6)`, CIANBLIS.m:128); `TCPREADL` ends the field list the
  instant a field's L() length-prefix HEADER byte equals it
  (`Q:X=CIA("EOD")`, CIANBLIS.m:233). That header is
  `(quotient_byte_count << 4) | (len % 16)`, so `\x1e` (high nibble 1) collided
  with every value whose byte length was `14 mod 16` in the 16..4095 range — a
  30-byte list-param value packs header `\x1e`. Over the wire this truncated the
  frame mid-field and the broker dropped the session, so a registration round
  trip died on its SECOND `DDR FILER` ("Connection closed by server") while the
  identical `FILEC^DDR3` succeeded in-process. `\x7f` (high nibble 7) would
  require a `>= 2**52`-byte value to appear as a header, so no L()-packed field
  can ever collide with it; DEL is also absent from RPMS ASCII reply text.
- The `StrictCiaBrokerSocket` test double now models `TCPREADL`'s
  terminate-on-`EOD`-header behaviour, so the two-FILER drop reproduces at the
  unit level (it previously could not express the failure).
- Corrected the call sites that documented `RS == the CIA EOD` as a standing
  wire fact: `Agg::RECORD_SEP`, `Patient::LOOKUP_RECORD_SEP`,
  `CiaClient::AGG_ARRAY_END`, `CiaClient#call_rpc_global_array`,
  `Client#read_until_raw` and `MockClient#truncate_at_eod`. The record
  separator stays `\x1e`; only the terminator moved, so those comments would
  otherwise assert a collision this change removes. `call_rpc_global_array`
  remains the correct read for type-4 replies — it frames on the `$C(31)`
  sentinel rather than relying on the terminator not colliding.

## [Unreleased]

### Fixed — sign-on `user_type` is the server's user class, not the message count (#236)

`DataMapper.define(:av_code)` declared `line_field 5, :user_class`. The
reply is VALIDAV^XUSRB's RET() array — `RET(0)=DUZ RET(1)=XUM RET(2)=VCCH
RET(3)=message RET(4)=0 RET(5)=post-sign-on message count RET(5+n)=the
message lines` (XUSRB.m:9-11, :40, :85-87). Against a real broker the
"class" was 0 for nearly everyone, so `Authentication::USER_TYPES` resolved
every user to `"user"`, and a host reading `user_type` for
provider/nurse/clerk checks saw them all false.

- **Breaking:** `Authentication.authenticate` no longer carries `:user_type`.
  The class is a separate read, `Authentication.user_type(duz)`, made once the
  session holds a context: `ORWU USERINFO` piece 3, USRCLS, which ORWU.m:19
  computes from the user's order keys (3 ORES, 2 ORELSE, 1 OREMAS, 0 none)
  and which CPRS reads the same way. It answers `"provider"`, `"nurse"`,
  `"clerk"` or `"user"`, and raises `Client::RpcError` when the class cannot
  be read (the RPC is refused or fails, answers nothing, answers for another
  DUZ, or answers a USRCLS ORWU.m:19 never returns; the raw piece is checked,
  not a coerced number). It never claims a default class. A host that stored
  `user_type` from the sign-on result calls `user_type` after binding its
  context. `Authentication::USER_TYPES` is re-keyed to USRCLS;
  `Authentication.user_type_for(usrcls)` is new.
- Fixed: `Authentication.authenticate` now marks the client signed on (`Client#set_authenticated`)
  when the broker accepts the pair. It did not, so a host that signed on through it could not bind
  the context `user_type` needs: `create_context` raised "Not authenticated".
- Fixed: each sign-on attempt clears the client's identity before it re-binds the broker session
  (`Client#clear_authenticated`), so a failed second sign-on no longer leaves the client signed on
  as the first user.
- Added: `:post_signon_message_count`, XUS AV CODE line 5, on the success
  result. `:av_code` seeds take `post_signon_message_count:`.
- `MockClient#seed_user(role:)` seeds the role as ORWU USERINFO's USRCLS.

**Breaking:** `Authentication.user_info(duz)[:user_class_ien]` is renamed
`:dtime`. Line 7 of `XUS GET USER INFO` is DTIME (USERINFO^XUSRB2,
XUSRB2.m:35), never a user class; no known host reads it. `:user_info`
seeds take `dtime:`.

`test/live/user_role_live_test.rb` proves, for each persona, that
`Authentication.user_type` equals the mapping of a direct `ORWU USERINFO` call, and
that `XUS GET USER INFO` line 7 equals the user's TIMED READ (200.1).

### Fixed — orders reads match what ORWOR / ORWORR emit (#220)

Each mapping's parameters and row layout now come from the FOIA routine
(`ORWOR.m`, `ORWORR.m`, `ORWORR1.m`, `ORWOR2.m`) and the pinned registry
formals; before, every one was a placeholder that shifted or dropped fields.

- `Order.list(dfn, filter: :active, display_group: 1)` —
  `AGET(REF,DFN,FILTER,GROUPS,...)^ORWORR`: FILTER is an `ORDSTS^ORCHANG2`
  view id (`Order::FILTER_IDS`), GROUPS a file 100.98 IEN (AGET's default 1).
  Rows are `IFN;ACT^DGrp^ActTm^PtEvtID^EvtName` (ORWORR1.m:11) ->
  `order_id`, `ien`, `display_group_ien`, `action_datetime`, `event_ien`,
  `event_name`; the `.1` header `TOT^TXTVW^ORYD` is dropped. AGET returns no
  order text. **Signature change** (`view:` / `status:` are gone).
- `Order.unsigned_for_patient(dfn)` replaces `unsigned_for_user(duz)` —
  `UNSIGN(LST,ORVP,HAVE)^ORWOR` takes the patient; rows are `IFN;ACT`
  (ORWOR.m:127) -> `order_id`, `ien`, `action_ien`.
- `Order.expired_search_start` replaces `expired?(order_ien)` —
  `EXPIRED(ORY)^ORWOR` takes nothing and answers the FileMan date/time to
  search for expired orders from (ORWOR.m:147-150), now a `Time`.
- `Order.result_history(dfn, order_ien)` — `RESHIST(REF,DFN,ORID,ID)^ORWOR`:
  RESULT's formals, and a display report returned as text, not typed rows.
  **Signature change.**
- `Order.sheets_for_patient` — `SHEETS(LST,ORVP)^ORWOR` rows `TYPE;ID^label`
  (ORWOR.m:97-105) keep `sheet_id` whole and add `event_type`, `event_ref`,
  `label`.
- `test/live/order_live_test.rb` proves the five reads against the pinned
  build (AGET's header per filter id, rows checked against file 100, the
  EXPIRED arithmetic against the server's NOW, the sheets every patient has,
  the no-results report). The fabricated-reply cases in `order_test.rb` are
  gone. Row-layout specs wait on an order in the demo data (#391).

### Added — the gem conforms to a pinned rpms-ops build's RPC signature (#222, #160)

- `rake conformance:pin RELEASE=<tag>` pins the RPC signature rpms-ops publishes on a
  release: the `#8994` + `#9.4` inventory and the build record. It checks every file against
  the release's asset digest, the sidecar, the artifact binding, and that the build record's
  commit is the one the tag names. It commits the five files unchanged under
  `data/inventories/<tag>/`, derives `data/fingerprints/references/<tag>.yml`, and records
  tag, RPMS version, engine, build commit and sha256s in `data/fingerprints/rpms-ops.lock.yml`.
  Pinned: `bcer-9.0-20260930-8c88e47-ydb` (the first real reference fingerprint).
- `test/rpms_rpc/registered_rpc_names_test.rb` reads the pinned build. A name the gem uses
  fails when it is not registered there, has no entry point, or is INACTIVE for local use.
- `test/rpms_rpc/pinned_build_signature_test.rb` fails when the lock does not name the
  build, when the committed signature or the fingerprint drifts from the lock, or when a
  wire fixture cites a different entry point from the one the build registers for its RPC.
- `rake conformance:ingest` reads the `#8994` 0-node by its DD: field 4 is RETURN VALUE TYPE
  and field 5 AVAILABILITY. Before this, AVAILABILITY was stored as `return_type`.

### Removed — `data/rpc_coverage/registry/` (#222)

- The names-only copies of the 0913 registry and package list. `rake rpc:coverage` reads the
  pinned signature (`release:` in `data/rpc_coverage/config.yml`). The 0930 `#8994` dump is
  byte-identical to 0913's (same sha256), so the coverage number does not move.

### Changed — BREAKING: a missing RPC raises a typed error instead of answering empty (#363)

- No API method checks whether the server serves its RPC before calling it.
  The guards that answered `[]`, `nil` or a canned
  `{ success: false, error: "... not available on this server" }` hash are
  gone from `Patient.brief_header` (which also stops rescuing a
  "doesn't exist" error into `nil`), the ten ORQQPL methods on `Problem`
  (`lex_search`, `clinic_search`, `details`, `audit_history`, `comments`,
  `init_patient`, `provider_list`, `edit_load`, `inactivate`, `verify`) and
  the eighteen BMC methods on `Referral`. Each now sends its RPC and raises
  when the server will not run it. A host that read empty as "feature
  absent" must rescue the error instead.
- New `Client::RpcNotAvailableError < RpcError`: the server does not serve
  the RPC (no #8994 entry, or inactive). New `Client::RpcRefusedError <
  RpcError`: the RPC is served, but not to this user in the bound context
  option. Any other broker error is still a plain `RpcError` (chiefly an M
  error from a routine that ran). CIA (error 3 / error 4), XWB and BMX raise
  the same class for the same case.
- XWB reads the SNDERR header by its length bytes. A refusal used to be
  recognised only when its length byte happened to be absent or `E`, so most
  "doesn't exist" refusals and every "not registered to the option" refusal
  came back as reply data.
- BMX raises `RpcNotAvailableError` / `RpcRefusedError` for a refusal in the
  security packet, where it raised `ConnectionError`.

### Removed — BREAKING: capability probes (#363)

- `RpmsRpc::ServerCapabilities` (its feature registry, `register`, `probe`
  and the `server_capabilities/` files), `Client#supports?` and
  `MockClient#supports?` / `MockClient#seed_capability`. A host that passes
  `supports?` through a wrapping broker (for example in a PASSTHROUGH list of
  delegated client methods) must drop it.
- `rake rpc:coverage` no longer reads capability-probe `register([...])`
  lists, since there are none.

### Added — `Authentication.held_keys(names)`, through CIAVCXUS HASKEYS (#318)

The registered way to ask which of several named security keys the
signed-on user holds, replacing the removed `user_security_keys`. One
`CIAVCXUS HASKEYS` call (HASKEYS^CIAVCXUS, CIAVCXUS.m:14-18: the names
joined with `^`, one 0/1 piece per name), in `CIAV VUECENTRIC`, so a
least-privilege CIA user can ask. Returns the names held, in the order
asked; `nil` when the broker refuses or the reply does not answer every
name, so a consumer can tell "holds none" (`[]`) from "could not ask"
(`nil`); `[]` without a call for an empty list. Names containing `^` or
beginning with `@` (a parameter, not a key, CIAVCXUS.m:11) raise
`ArgumentError` before anything is sent.

### Changed (breaking): reminders come from the reminder engine, not the triage summary (#238)

- `RpmsRpc::Reminders.for_visit(dfn, visit_ien)` is removed.
  It read `BGOTRG GETSUM`, the triage summary.
  `GETSUM^BGOTRG` renders chief complaint, vitals, reproductive history, pregnancy, immunizations, skin tests, education, exams, health factors, procedures and orders (`BGOTRG.m:27-158`).
  It never reads a reminder, so the `id^name^status^priority^due` the mapping took from it did not exist on the wire.
  The `:reminder_summary` mapping is gone, and so is its `data/rpc_tiers/grandfathered.yml` entry.
- `RpmsRpc::Reminders.applicable(dfn, location_ien = nil)` replaces it.
  It reads `ORQQPXRM REMINDERS APPLICABLE`, the method RPMS has in place for this question.
  The call goes `APPL^ORQQPXRM` (`ORQQPXRM.m:10-11`) to `EVALCOVR^ORQQPX` (`ORQQPX.m:232-236`), which evaluates the cover-sheet reminder list through `AVAL^PXRMRPCA` (`PXRMRPCA.m:49-82`).
  The new mapping `:reminders_applicable` declares that row as the routine builds it (`PXRMRPCA.m:76,80`).
  Each row is a hash:
  - `id` and `name`
  - `due_flag` and `status`. Status is derived from the flag: 0 `:applicable`, 1 `:due`, 2 `:not_applicable`, 3 `:error`, 4 `:cannot_be_determined`.
  - `due_date`: a `Date` only when RPMS sent a FileMan date.
  - `due_now`: `true` when RPMS sent the literal `DUE NOW`.
  - `last_done`, `priority` and `has_dialog`.

  Not-applicable rows are returned, as RPMS returns them.
  The status vocabulary changed: `:satisfied` is gone, and `:not_applicable`, `:error` and `:cannot_be_determined` are new.
- RPMS keys this read by patient and hospital location (#44), not by visit.
  **lakeraven-ehr must move its caller.**
  - `app/gateways/lakeraven/ehr/reminders_gateway.rb:10-12` calls `via.for_visit(dfn, visit_ien)`.
  - `app/services/lakeraven/ehr/encounter_lifecycle_service.rb:68` calls the gateway the same way.

  Both should call `RpmsRpc::Reminders.applicable(dfn, location_ien)`.
  The encounter's location is already available from `RpmsRpc::Encounter.open(dfn, visit_ien)[:location_ien]`.
  The stubs in `features/step_definitions/encounter_lifecycle_steps.rb:37` and `test/gateways/lakeraven/ehr/reminders_gateway_test.rb:25,32` follow.
- Formatted vitals were never a reminder concern.
  Value, unit and timestamp as separate fields come from `RpmsRpc::Measurement.for_visit` / `.latest`.
- The mapping is unverified under ADR 0003 sections 2 and 5.
  Its wire fixture (`test/fixtures/wire_captures/orqqpxrm-reminders-applicable.yml`) is a `routine-cite`, and the live capture is still owed.

### Removed — BREAKING: 77 RPC names no built image registers, with the API that sent them (#207, #295)

A name is only real if a built baseline registers it. 77 of the names the
gem used (268 declared) are in `#8994 REMOTE PROCEDURE` on neither a built
9.0 YottaDB image nor a built 9.0 IRIS image, and 75 of them appear nowhere
in the FOIA source either: they were written from belief, and every one
that was sent live answered `Unknown remote procedure`. They are gone,
together with every API method, capability probe, mapping, fixture and test
that existed only to send them. Nothing was repointed: no registered RPC
had its wire shape evidenced in the repo as the replacement, and the
default for an invented name is deletion, not a guess at its real twin.

`test/rpms_rpc/registered_rpc_names_test.rb` now fails when any name the
gem uses is on no pinned registry (now the pinned rpms-ops build signature, #222), and
`rake rpc:coverage`'s `max_unregistered` ratchet is 0. To add an RPC: pin
its registry capture first, then map it (ADR 0003).

Stock-VistA clusters (first PR):

- `RpmsRpc::Communication` — the whole module (`find`, `for_patient`,
  `search`, `send_message`, `reply_to_message`, `get_thread`, `for_user`,
  `get_alerts`, `alert_count`, `mark_alert_read`, `forward_alert`): XM GET
  MESSAGE / MESSAGES / THREAD / INBOX, XM SEND / REPLY MESSAGE, XQAL NEW
  ALERTS / MARK READ / FORWARD. No mail RPC surface is registered at all;
  the registered alert read is XQAL GUI ALERTS.
- `RpmsRpc::CarePlan`, `RpmsRpc::CareTeam`, `RpmsRpc::Goal` (`for_patient`,
  `find`): ORQQCP / ORQQCT / ORQQGO LIST and GET — namespaces CPRS does not
  have.
- `RpmsRpc::Lab` (`for_patient`, `abnormal`, `reports`, `find`,
  `build_list_param`): ORWLRR RESULT LIST / REPORT LIST / REPORT. The
  registered ORWLRR reads are INTERIM / ATOMICS / CHART / GRID / ....
- `RpmsRpc::Radiology` (`for_patient`, `find`): ORWRA REPORT LIST / REPORT.
  The registered reads are ORWRA REPORT TEXT / REPORT TEXT1 and ORWRA
  IMAGING EXAMS / EXAMS1 (`Image.exams_for_patient` keeps the latter).
- `RpmsRpc::Device` (`for_patient`, `find`): ORWPCE IMPLANT LIST / GET.
- `RpmsRpc::Procedure.for_patient`: ORWPCE PROCEDURE LIST (the unused
  ORWPCE PROCEDURE GET mapping with it). `Procedure.add` (BGOVCPT SET) stays.
  **Kept, rebuilt on BGOVCPT GET** (GET^BGOVCPT, the V CPT read VueCentric's
  procedure component uses): same call, `for_patient(dfn)` still returns a
  list of hashes with `:ien`, `:name`, `:date` and `:provider`. The field map
  changes: `:ien` is the V CPT IEN, `:name` the provider narrative, `:date`
  the visit date, `:provider` a name; added `:cpt_code`, `:cpt_name`,
  `:visit_ien`, `:quantity`, `:diagnosis`, `:modifier_1`/`:modifier_2`,
  `:facility`. V CPT has no status, so `:status` is gone. Proved live by
  `test/live/procedure_live_test.rb` against a V CPT entry on the 0930 build.
- `RpmsRpc::Eprescribing` (`transmit`, `status`, `cancel`,
  `build_rx_param`): PSO NEW RX / ERX STATUS / CANCEL RX. No PSO RPC is
  registered on either image.
- `RpmsRpc::HealthSummary.types` and `.type_components` (ORWRP TYPES / TYPE
  COMPONENTS), `.personal_wellness_report`, `.flowsheet_definitions`,
  `.flowsheet`, `.health_maintenance` (GMTS PWH REPORT / FLOWSHEET LIST /
  FLOWSHEET DATA / MAINT ITEMS). `for_patient(summary_type:)` now resolves
  the type against the static `DEFAULT_TYPES` list — which is what every
  real server already got, since the probe never found ORWRP TYPES. The
  registered health-summary surface is ORWRP2 HS *.
- ORWU USERKEYS. `RpmsRpc::Authentication.user_security_keys` is kept,
  rebuilt on DDR LISTER (see "Kept" below).
- `RpmsRpc::UserManagement.grant_key`, `.revoke_key`, `.list_all_keys`
  (XU KEY GRANT / REVOKE / LIST); `UserManagement.find` no longer returns a
  `:security_keys` entry (it came from ORWU USERKEYS).
- Mappings with no caller: `:patient_recent` / `:patient_save_recent`
  (ORWPT LIST RECENT / SAVE RECENT).
- `ServerCapabilities` features `:user_security_keys_list`,
  `:health_summary_gmts`, `:xu_key_admin`, `:pso_prescription_orders`,
  `:xqal_alert_actions`, `:orwlrr_lab_reports`, `:orwra_radiology_reports`,
  `:orwpce_clinical_logs`, `:orwrp_report_types` — all probed removed names.
- `MockClient#seed_user` no longer takes `security_keys:` (it seeded ORWU
  USERKEYS).

IHS clusters (second PR):

- `RpmsRpc::ChsBudget` — the whole module (`fiscal_year_budget`,
  `remaining_funds`, `quarterly_allocation`, `obligations`, `find`,
  `by_referral`, `payments`, `outstanding_obligations`, `obligation_summary`,
  `budget_summary`, `low_funds?`, `current_fiscal_year`, `current_quarter`):
  BMCRPC GTBUDGET / GTREMAIN / GTQTRALLOC / GTOBLIG / GTOBLIGID / GTREFOBLIG
  / GTPAYMENT. The names were built from RCIS's routine prefix; the real
  RCIS surface is BMC *, 20 of which the gem keeps (BMC ADD SECONDARY
  REFERRAL is dropped below).
- `RpmsRpc::Vendor` (`search`, `find`, `preferred`, `for_service`,
  `contracts`, `active_contract`, `rates`, `active?`): BMCRPC SRCHVEND /
  GTVEND / GTPREFVEND / GTCONTRACT / GTRATES.
- `RpmsRpc::RcisSiteParams.for_facility`: BMCRPC GTSITPRM.
- `RpmsRpc::Referral.delete`: BMCRPC DELREFRL. **Added `Referral.cancel(ien)`;
  replaces `Referral.delete`.** RCIS has no delete; the real verb is a status
  change. `cancel` files STATUS OF REFERRAL (90001, .15) as `X`
  (CLOSED-NOT COMPLETED, which RCIS's reports treat as cancelled) through
  BMC REFERRAL STATUS UPDATE (UPDTSTRF^BMCRPC3), under the BMCRPC option.
  It takes no `reason:`, because the routine files no reason. It returns
  `{ success:, message:, raw: }`. On builds without rpms-ops#702 a refusal
  raises `Client::RpcError`. Proved live by
  `test/live/referral_cancel_live_test.rb`, which cancels a referral on a
  disposable container, reads the status back and files it active again.
- BIPC ELIGGET / ELIGLIST. `RpmsRpc::Eligibility` (`for_patient`, `codes`)
  is kept, rebuilt on BGOVIMM GETVFC / BGOVIMM2 GETELIG (see "Kept" below).
- `RpmsRpc::VaccineLot` (`for_facility`, `find`): BIPC LOTLIST / LOTGET.
- `RpmsRpc::Immunization.for_patient` and `.find`: BIPC IMMLIST / IMMGET.
  `Immunization.text_summary` (BEHOCIR GETTXT) stays. No BIPC RPC is
  registered; the registered immunization surface is BGOVIMM* and BYIM *.
  **Kept, rebuilt on BGOVIMM GET** (GET^BGOVIMM5, the immunization history
  VueCentric's immunization component reads): same calls, `for_patient(dfn)`
  returns a list and `find(ien)` one dose or nil, with the removed read's
  keys. `find` asks FileMan (DDR GETS ENTRY DATA, file 9000010.11) which
  patient a dose belongs to and filters that patient's read. Changed: the
  routine returns no CVX, status, expiration date, route, dose unit, VFC
  eligibility code or funding source, so `:vaccine_code`, `:status`,
  `:expiration_date`, `:route`, `:dose_unit`, `:vfc_eligibility_code` and
  `:funding_source` are no longer returned. A key with no value is left out.
  `:vaccine_display` is the vaccine's full name, and `:occurrence_datetime`
  is the event date. Proved live by `test/live/immunization_live_test.rb`
  against the V IMMUNIZATION entries on the 0930 build.
- `RpmsRpc::ImmunizationExchange` — the whole module (`send_immunizations`,
  `submit_query`, `for_patient`, `retrieve_response`, `process_responses`,
  `check_status`): BYIMRT VXU / VXQ / RSP / STATUS. VXQ / VXU / RSP are
  entry points in the routine, registered as RPCs nowhere; the registered
  exchange RPCs are BYIM SEND IMMS TO SIIS / QUERY SIIS / DISPLAY IMM AND
  FORECAST.
- `RpmsRpc::Phr.patient_direct_address`, `.provider_direct_address`,
  `.facility_direct_domain`, `.record_access`: BPHR PATIENT / PROVIDER /
  FACILITY DIRECT, BPHR RECORD ACCESS. No BPHR RPC is registered.
- BHDO HOSP LOC DATA, an invented namespace. `RpmsRpc::Location.find` is
  kept, rebuilt on DDR GETS ENTRY DATA over #44 (see "Kept" below).
- BHDO INST DATA, the same invented namespace. `RpmsRpc::Organization.find`
  is kept, rebuilt on DDR GETS ENTRY DATA over #4 (see "Kept" below).
- `RpmsRpc::Capabilities.imaging_user?` and `.clear_imaging_cache!`:
  MAGGUSERKEYS. The registered imaging key check is MAGGDUZKEY.
- `RpmsRpc::Image.launch_token` (and `Image::DEFAULT_TTL_SECONDS`): MAGG
  IMAGE LAUNCH TOKEN.
- `RpmsRpc::Notifications.mark_read`: BQI MARK ALERT READ. The registered
  acknowledgement verbs are BQI SET COMM ALERTS * and BQI UPDATE
  NOTIFICATION STATUS.
- Mappings with no caller: `:section_data` / `:section_save` /
  `:section_definition` / `:patient_lock` / `:patient_unlock` (BEHOENCX GET
  SECTION / SAVE SECTION / GET SECDEF / LOCK / UNLOCK — the routine is real,
  these tags are not).
- `ServerCapabilities` feature `:bphr_phr_endpoints`.
- `RpmsRpc::Referral.add_secondary`: BMC ADD SECONDARY REFERRAL. Registered,
  but not callable on any built image: #8994 points it at SETSCNRF^BMCRPC2,
  and the tag lives in BMCRPC4 (FOIA BMCRPC4.m:144), so the broker finds no
  entry point (rpms-ops#653). The registered-names gate cannot see this;
  the 0921 RPC atlas classifies it `no-entry-point`. It comes back when the
  build registers it where the routine is.

The hand-authored `data/fingerprints/references/bcer-8.0.yml` seed no
longer lists these names as "gem-required RPCs the staging dump lacks":
they were never capability gaps, only invented mappings.

### Kept — rebuilt on the registered RPC (#207)

Methods the host application calls whose invented RPC was removed above are
kept with the same name, arguments and return shape, rebuilt on the RPC the
built image really registers, and proven by a live spec as the programmer
and the provider persona:

- `RpmsRpc::Location.find(ien)` → `{ien:, name:, abbreviation:, type:,
  division:}`: kept, rebuilt on DDR GETS ENTRY DATA over HOSPITAL LOCATION
  #44 (.01, 1, 2, 3.5), in CIAV VUECENTRIC. `type` and `division` are the
  external forms ("CLINIC", the division's name). BEHOENCX LOCINFO is not
  usable: it M-errors (an extrinsic `QUIT` under `DO`).

- `RpmsRpc::Authentication.user_security_keys(duz)` → `[key names]`: kept,
  rebuilt on DDR LISTER over the user's KEYS multiple (#200 field 51,
  subfile 200.051; .01 KEY points to #19.1), in CIAV VUECENTRIC.

- `RpmsRpc::Eligibility.codes` → `[{code:, label:}]` and
  `.for_patient(dfn)` → `{code:, label:}`: kept, rebuilt on BGOVIMM2
  GETELIG (active rows of #9002084.83) and BGOVIMM GETVFC, the reads of
  VueCentric's immunization component, in CIAV VUECENTRIC. GETVFC answers a
  default LABEL ("Am Indian/AK Native" for beneficiary type 1 at an IHS
  site), which `for_patient` resolves to its code; any other default is
  `NIL_ELIGIBILITY`.

- `RpmsRpc::Organization.find(ien)` → `{ien:, name:, station_number:,
  address:, city:, state:, zip_code:, phone:}`: kept, rebuilt on DDR GETS
  ENTRY DATA over INSTITUTION #4 (.01, 99, 1.01, 1.02, 1.03, .02, 1.04), in
  CIAV VUECENTRIC. `state` is the state's name (the external form of the
  pointer to #5). `phone` is always nil: file #4 has no phone field.

### Added — transport security: the broker connection is plaintext, and how to wrap it (#113)

- `docs/tls.md` explains why the gem ships no TLS and gives the deployment
  patterns: a private network or an SSM/SSH port forward, stunnel at both ends,
  WireGuard/IPsec, and a customer-side connector. `SECURITY.md` gains a
  "Transport security" section, and the README links both.
- Sample stunnel configs (`docs/tls/stunnel-app-side.conf`,
  `docs/tls/stunnel-rpms-side.conf`) with mutual TLS, chain and host checks and
  a TLS 1.2 floor. `stunnel_sample_test.rb` runs them against a fake CIA broker.
  CI installs stunnel for it.

### Fixed — a refused CIA sign-on names the broker's reason; CIA frames go through send_packet (#175)

- `CiaClient#authenticate` raised a bare `"CIA sign-on rejected"`. It now
  carries the broker's reason: the text of `DATA(0)` from `CHK^CIANBRPC`
  (e.g. `CIA sign-on rejected: Not a valid ACCESS CODE/VERIFY CODE pair.`), or
  a `\x01` broker error's text. The login banner that follows a refusal is not
  included. The access code, verify code and encrypted AVC are removed from the
  reason even if the broker echoes them, the reason is capped at 160
  characters, and the message still passes through `RpmsRpc.sanitize_error`.
- `CiaClient#exchange` writes each frame through `Client#send_packet`, as the
  XWB and BMX clients do, so a `SocketError` on write raises `ConnectionError`
  and leaves the client disconnected instead of escaping raw.

### Changed — `require "rpms_rpc"` is the entry point; `rpms_rpc/version` holds only VERSION (#7)

- New `lib/rpms_rpc.rb`: one `require "rpms_rpc"` loads configuration
  (`configure`, `client`, `mock!`, `reset!`), the response mappings, the
  security-key, role and capability tables, and every module under
  `lib/rpms_rpc/api/`. Consumers no longer need to know that
  `rpms_rpc/version` was the file that defined `mock!`.
- **Breaking for anyone relying on the old side effect:** `require
  "rpms_rpc/version"` now defines `RpmsRpc::VERSION` and nothing else (the
  gemspec loads it). Code that required it to get `SecurityKeys`, `UserRoles`,
  `Capabilities` or the mappings should `require "rpms_rpc"` instead.
- The configuration surface stays in `rpms_rpc/core.rb`, so a single broker
  client (`require "rpms_rpc/cia_client"`) still loads without the tables.

### Fixed — the two registration paths name the community they do not file (#300)

Each registration path ignored the other's community attribute without
saying so. The composition path (no AG) now names `community_ien:` and
`community_since:` in `unfiled:` when given: it files `community:` into 1118
as free text and has no 1117 pointer or #9000001.51 history entry. The
delegation path now names free-text `community:` in `unfiled:` even when the
pointer is given too, since AG's window has no free-text parameter. The
`Registration` module doc states what each path stores for community.

### Fixed — `:patient_id_info` reads ORWPT ID INFO as the routine writes it (#191)

IDINFO^ORWPT returns `PID^DOB^SEX^VET^SC%^WARD^RM-BED^NAME` (ORWPT.m:6-11).
The mapping declared piece 4 as `:race_code` and piece 6 as `:site_ien`; the
wire-contract gate caught both on its first run against the committed
capture (`test/fixtures/wire_captures/orwpt-id-info.yml`), where the "N"
read as a race code is the VETERAN flag and the "site IEN" piece is the
current ward, empty for an outpatient. The mapping now declares `:veteran`,
`:sc_percent`, `:ward_location` and `:room_bed` at those positions, its
`KNOWN_DIVERGENCES` pin is gone, and the gate is green on it. **Breaking:**
`Patient.find` no longer merges `:race_code` / `:site_ien` from this RPC —
they were never on it. The companion `:problem_list` divergence was already
fixed by #188; the pin list is now empty. Verified live: the new layout
parses a synthetic patient's reply from a local container of a built 9.0
YottaDB image.

### Fixed — the TIU note surface sends what its routines declare and reads what they answer (#219)

Line numbers are the FOIA source (Text Integration Utility/Routines).

- `ProgressNote.lock(note_ien)` — `LOCK(ERR,TIUDA)^TIUSRVP` answers `0` when
  it holds the lock and `1^ Another session has this record locked.` when it
  does not (TIUSRVP.m:210-212). The `:boolean` read reported a FAILED lock as
  held. One actual; the user DUZ is gone. **Signature change.**
- `ProgressNote.unlock(note_ien)` — `UNLOCK` always answers `0`
  (TIUSRVP.m:214-215), which read as false. **Signature change.**
- `ProgressNote.create(dfn, visit_ien, title_ien)` — frames
  `MAKE(SUCCESS,DFN,TITLE,VDT,VLOC,VSIT,...)` (TIUSRVP.m:7) as DFN, TITLE,
  `""`, `""`, VSIT. The old frame put the visit in TITLE and the title in VDT.
- `ProgressNote.authorize(note_ien, action: "EDIT RECORD")` — `CANDO(TIUY,
  TIUDA,TIUACT)^TIUSRVA` takes an action string, not a DUZ (TIUSRVA.m:20);
  `1` is yes, `0^reason` no. **Signature change.**
- `ProgressNote.list(dfn, context:, early:, late:, person:)` — sends CLASS 3
  (progress notes, TIUSRVLO.m:8), CONTEXT, DFN (TIUSRVLO.m:16); the old
  `(dfn, code)` frame always came back empty. Contexts are the routine's own
  (TIUSRVLO.m:19-23): `:all_signed` (default), `:unsigned`, `:uncosigned`,
  `:signed_by_author`, `:signed_by_date_range`; `:all`, `:by_author` and
  `:by_visit` are gone. Rows parse as `DA^DOC^EDT^PT^AUT^LOC^STATUS^...`
  (TIUSRVLO.m:94, 197), with `:author_duz` / `:author_name` split out of
  AUT. **Signature change.**
- `ProgressNote.update_text(note_ien, text)` — sends TIUX as a list,
  `TIUX("HDR")="1^1"` and `TIUX("TEXT",n,0)` per line (TIUSRVPT.m:12, 18);
  success is the `TIUDA^PAGE^PAGES` acknowledgement (TIUSRVPT.m:38). A flat
  string failed every update with "Invalid text block header".
- `XwbClient` forms list subscripts as M literals, as `CiaClient` does:
  LINST^XWBPRS splices them raw (XWBPRS.m:152-156), so a string key is quoted
  (`"HDR"`, `"TEXT",1,0`). An unquoted key was a variable reference.
- `NoteTemplate.roots` / `items` — rows parse as NODEDATA's
  `IEN^TYPE^STATUS^NAME^...^HAS CHILDREN` (TIUSRVT.m:4-29); the old mapping
  read TYPE as the name, and `:parent_ien` (never in the row) is gone.
- `NoteTemplate.boilerplate(template_ien)` — `GETBOIL(TIUY,TIUDA)`
  (TIUSRVT.m:55) takes the template alone and returns UNEXPANDED text; the
  three-actual frame died in M. **Signature change.**

### Fixed — read calls send the formal list each routine declares (#259)

Thirteen read calls died in M with `%YDB-E-LVUNDEF` (once with
`%YDB-E-ACTLSTTOOLONG`) because the frame carried fewer arguments than the
routine's label line declares. The formal lists come from the routines on a
built 9.0 YottaDB image; every fix below was proven live against a local
container of that image (the call answers, no M error).

- `Medication.for_patient` — `LIST(ORY,ORPT,ORSTRTDT,ORSTOPDT)^ORQQPS`: sends
  both dates, empty (OCL^PSOORRL `$G`s them and starts 120 days back).
- `Problem.for_patient` — `LIST(ORPY,DFN,STATUS)^ORQQPL`: sends STATUS `""`
  (all problems).
- `Problem.details(dfn, ien)` — `DETAIL(Y,DFN,PROBIEN,ID)^ORQQPL`: the
  patient comes first; the IEN-only frame put the IEN in DFN. **Signature
  change.**
- `HealthSummary.for_patient` / `component_data` —
  `RPT(ROOT,DFN,RPTID,HSTYPE,DTRANGE,EXAMID,ALPHA,OMEGA)^ORWRP`: seven
  formals instead of one `"DFN^type^"` string; RPTID is the Health Summary
  entry of file 101.24 (ID 1), HSTYPE the type IEN. `component_data` now
  fetches the summary and picks the component's section out of it: the RPC
  has no component selector for that report.
- `NoteTemplate.text(lines, dfn:, visit_string:)` —
  `GETTEXT(TIUY,DFN,VSTR,TIUX)^TIUSRVT` expands boilerplate TEXT; there is no
  template IEN on this wire, and the text must arrive as `TIUX(n,0)`
  (BLRPLT^TIUSRVD). `CiaClient` and `XwbClient` now frame an Array list
  key as a multi-level subscript (`[1, 0]` -> `P3(1,0)`). **Signature
  change.**
- `Order.result(dfn, order_ien)` — `RESULT(REF,DFN,ORID,ID)^ORWOR`: the
  patient first, the order IEN as ORID and ID. **Signature change.**
- `Symptom.search` — `SYMPTOMS(Y,FROM,DIR)^ORWDAL32`: sends DIR `1`.
- `Vital.template(dfn, visit_string, metric: -1)` —
  `TEMPLATE(DATA,DFN,VSTR,METRIC)^BEHOVM`: a patient and a visit string, not
  a location IEN; METRIC as the routine reads it (-1 default units, 0 US,
  1 metric). **Signature change.**
- `Patient.brief_header` — the three `BEHO*` frames that died (`DFN`
  undefined) were not the fetches, which carried the DFN, but the
  `:patient_chart_banner` capability probe, which called each RPC with no
  parameters. `ServerCapabilities.register` takes `probe:` parameters per
  RPC and the banner probe sends DFN `"0"`, which each routine answers
  empty. The same probe class explains the `ORQQPL DETAIL ... PROBIEN`
  error logged under `Problem.provider_list` / `lex_search`: the
  `:orqqpl_problem_workflow` probe called DETAIL bare, and DETAIL has no
  safe synthetic input, so that feature now probes `ORQQPL INIT PT`
  (quits on a zero DFN).
- `BGOPROB GET CLASS` (more actuals than formals) was already unbound on
  `main`; nothing in the gem sends it.

### Fixed — CIA read_reply correlates a reply to its request by the sequence echo (#289)

`CiaClient#read_reply` accepted any non-empty piece as this request's reply. It
skipped an EMPTY piece (a late bare EOD), but a NON-EMPTY stale tail — the
remainder of an earlier reply whose global-array body embedded EOD and was read
short (#254, measured on BSDX HOSPITAL LOCATION / BMC HEALTH SUMMARY TYPE) —
was returned as this call's answer, putting the whole session one call late.
`discard_stale_bytes` drains the socket at one instant before the write; a tail
still in flight at that instant arrives afterwards, which draining cannot catch.

`read_reply` now matches on the one-byte **sequence echo** that CIANBLIS writes
ahead of every reply (`W SEQ`, CIANBLIS.m:135). A piece whose first byte is not
the current `@seq` is a stale tail (its first byte is an earlier reply's data,
not our echo) and is skipped; once the small read budget is spent with no
matching piece, it raises `ConnectionError` — fail closed, never hand the caller
someone else's bytes. A well-formed reply we return then carries a valid ack
flag — `\x00` DATA (CIANBLIS.m:261) or `\x01` ERROR (:268) — or none at all
(SNDEOD, :273-275); that shape is enforced by `parse_cia_reply`, which already
fails closed on anything else, so an echo-matching but malformed frame is
returned here and refused there rather than silently skipped into a desync.

New `test_an_in_flight_tail_with_a_mismatched_echo_is_not_the_next_reply`
reproduces the in-flight case: drain, then deliver a non-empty tail from the
previous reply, and assert the next call does not receive it. With the defect
reintroduced (accept any non-empty piece) it goes red — request 2 returns
`"7^CHART REVIEW^^"` instead of its own `"2\x00OK"`.

**Spec amendment — CIA reply fixtures carry a real sequence echo.** Correlation
by echo requires each canned reply to begin with the echo of the frame it
answers, advancing with `@seq`. Fixtures that hard-coded a single echo across
several exchanges (the re-auth and concurrency paths), or carried none at all,
were artifacts of the echo-blind reader; they are amended to the shape a real
broker sends, with the rationale recorded in each test. No production behaviour
rode on the old fixtures — only the test doubles changed.

### Fixed — BEHOENCX FETCH is sent its real signature; both visit layouts match the routine (#211, #213)

- `Encounter.open` sent `BEHOENCX FETCH` the visit IEN as its only
  parameter. The routine is `FETCH(DATA,DFN,VSTR,PRV,CREATE)`
  (BEHOENCX.m:32), so the IEN landed in `DFN` and `VSTR` was undefined
  (`S LOC=+VSTR` at VSTR2VIS+2, BEHOENCX.m:107). `open` now composes the
  call as the server expects: `GETVISIT(IEN)` → the extended visit string
  `LOC;VDT;SVC;IEN` from that reply → `FETCH(DFN, VSTR, "", CREATE=0)`.
  With the IEN in the VSTR, VSTR2VIS resolves the visit directly
  (BEHOENCX.m:107-111, no 60-minute FNDVIS window) and CREATE=0 can never
  create one.
- One mapping per RPC, each in the routine's layout with `routine.m:line`
  cites. `:encounter_fetch` is now
  `LOCNAME^LOCABBR^ROOMBED^PROVIEN^PROVNAME^VISITIEN^VISITID^LOCKED^ERRORTXT`
  (BEHOENCX.m:30-31, built at 41-46): its old piece 4 `:location_ien` was
  the PROVIDER ien and its piece 7 `:ward` the VISIT ID. The duplicate
  `:encounter_get_or_create` (same RPC, already in this layout) is gone;
  `Encounter.create` uses `:encounter_fetch`. `:encounter_visit` is
  `LOC^VDT^SVC^PAT^VID^LOCKED` (BEHOENCX.m:5,8-15 over LOOKUP^VSIT; #9000010
  fields .22/.01/.07/.05/15001 per VSITFLD.m:15-33); the `:status` alias on
  the SERVICE CATEGORY piece and the `:ward` alias on the VISIT ID piece are
  removed — nothing on either wire is an encounter status or a ward.
- `open()` keys stay stable for consumers, each from the piece that really
  carries it: `:location_ien` from GETVISIT's LOC (FETCH has none),
  `:location`/`:clinic_abbrev`/`:provider` from FETCH's LOCNAME/LOCABBR/
  PROVNAME, `:status` kept as the same value as the new
  `:service_category`. New: `:provider_ien`, `:room_bed`, `:visit_id`,
  `:locked`. Dropped: `:ward` (invented). `open` also returns nil when FETCH
  answers with its error piece instead of a visit (e.g. VIS2VSTR's "Visit
  does not belong to current patient", BEHOENCX.m:118).
- `Encounter.visit_string` takes `visit_ien:` for the extended form.
- Both RPCs are now in the wire-contract gate with **live captures** from a
  local YottaDB container of a built 9.0 image (`behoencx-getvisit.yml`,
  promoted from no-data; `behoencx-fetch.yml`, new, captured with
  CREATE=0 against the build's own test visit). The gate flagged exactly
  the positions the issues name (FETCH 3 and 6, GETVISIT 2 and 4) before the
  mappings were corrected.

### Removed — the `CIAVMRPC GETPAR` session-bootstrap mapping (#239) — **breaking**

`:session_default_source` wrapped `CIAVMRPC GETPAR` to fetch
`"CIAVM DEFAULT SOURCE"` at cold launch — the VueCentric client's own
config root, the path the Windows shell loads its component registry from.
Under ADR 0004 the RPC is tier V, coupling `vuecentric-framework`,
disposition legacy (disqualifier 2: it reads client session/widget state),
and it sat in the grandfathered ratchet. A frontend-agnostic consumer has
no CIAVM config root, so there is nothing for the value to mean; its other
use — reading site parameters such as `BGO CC PREFIX TEXT` — is site
configuration for the captured L2/L3 overlay, not an RPC round-trip. No
caller in this gem or in the consuming app read anything but the CIAVM
parameter, so the mapping is deleted rather than narrowed.

- `DataMapper[:session_default_source]` is gone; so is
  `Session::DEFAULT_SOURCE_PARAM`.
- `Session.bootstrap` no longer calls `CIAVMRPC GETPAR` and its result has
  no `:config_root` key; `:registry`, `:vim_info` and `:default_site_ien`
  are unchanged.
- The `"CIAVMRPC GETPAR"` entry leaves `data/rpc_tiers/grandfathered.yml`
  (the ratchet failed until it did), and `docs/RPC_COVERAGE.md` no longer
  counts a `CIAVMRPC` wrapper.

A consumer that seeded `:session_default_source` in its tests drops that
seed; one that read `bootstrap(...)[:config_root]` has no replacement,
because the value belongs to the legacy client.

### Fixed — Referral, Scheduling and BehavioralHealth bind their package option (#258)

RPC registration is OPTION-scoped: the broker answers "may this session run
this RPC?" from the RPC multiple of the option bound right now. On a built
9.0 image the RPCs these three APIs call are each listed under ONE file-19
option and under none of the options a signed-on session is otherwise
holding (not `CIAV VUECENTRIC`, which CIA sign-on binds since #257, and not
`OR CPRS GUI CHART`):

- the 21 `BMC *` names `RpmsRpc::Referral` calls — in `BMCRPC` only
  (22 entries, the other being `ORWDXIHS CLININD`); `BMCRPC DELREFRL` behind
  `Referral.delete` is registered in no option at all (#207) and the bind
  cannot help it;
- the 9 `BSDX *` names `RpmsRpc::Scheduling` calls — in `BSDXRPC` only
  (69 entries);
- the 40 `AMHG *` names `RpmsRpc::BehavioralHealth` and its clusters call —
  in `AMHGRPC` only (223 entries).

A user without `XUPROGMODE` was therefore denied every `BMC *`/`BSDX *` call
and left waiting on every `AMHG *` call. Each API now scopes its calls to
its option the way `RpmsRpc::Agg` scopes `AGGRPC`: bind, run, restore the
caller's option (`ContextScope.scoped`, new; a client that cannot scope
contexts runs as-is). `Referral` runs its `:bmc_referral_workflow`
capability probe inside the same scope, since `BMC GET REFERENCE DATA` is in
that multiple too. `BehavioralHealth::CONTEXT` lives in `wire.rb`, where
`Wire#call_amhg` — the one seam every AMHG call passes through — binds it.

Proven at the unit level only: a programmer-key session bypasses the context
check on both broker lines, so the issue's acceptance (a non-programmer run)
remains open.

### Fixed — AGG registration sends tribe, classification, eligibility and community through AG's own window (#297)

`Registration.register` documents `tribe:`, `classification:`,
`eligibility_status:` and `community:`, and on every RPMS stack (where
`Agg.available?`) it dropped all four: the create went through the "Mini
Registration" window, which has no parameter for them, and answered
`{ success: true }`.

The create now goes through **"New Patient"**, the window AG registers a new
patient through, which carries them as `AGGPTTRI`, `AGGPTCLB`, `AGGPTELG`,
and `AGGPTCOM` + `AGGPTCDT`. AG files them with the rest of the registration;
nothing is filed around AG. The window's 28 parameters are committed as
`test/fixtures/agg/new_patient_window.tsv` (read from `^AGG(9009068.3,28,10)`
on bcer-9.0-20260905-ydb), and a test fails if the create sends a name the
window does not define.

- Community on this path is AG's shape: `community_ien:` (COMMUNITY
  #9999999.05) with `community_since:` (the date moved). AG files the pointer
  (1117) and a dated history entry (#9000001.51) and derives the text (1118).
  One without the other raises `ArgumentError`. `community_since: :birth`
  (or `"B"`) is sent as the date of birth, and a value that is not a date
  raises: sent as `B`, AG answers success and files no community history.
- A value AG's window has no parameter for is not sent and is named in the
  result: `unfiled: [:community]` for free-text `community:` with no
  `community_ien:`, `unfiled: [:extra_fields]` for the composition path's
  escape hatch.
- The HRN update still uses "Mini Registration", where it was captured (#214).

Proven live on the 0905 image as a programmer-key user (a create with the
five parameters filed 1108, 1111, 1112, 1117, the #9000001.51 entry and
1118). Not yet proven as a least-privilege registration clerk.

### Fixed — disconnect ends the CIA session the way the broker expects (#192)

`CiaClient#disconnect` closed the TCP socket without sending the `{CIA}` quit
action. The single-session listener (CIANBLIS) does not notice a vanished peer
at EOF — only on its retry bound — so it sat draining a dead socket while the
next connection waited, measured at ~45 s per orphaned close against a built 9.0
YottaDB image. `disconnect` now sends the broker's disconnect action before
closing:

- The action is `"D"`. `DOACTION^CIANBLIS` takes the action from frame header
  byte 8 (`ACT=$E(X,8)`, CIANBLIS.m:128) and dispatches
  `D @("ACT"_ACT_"^CIANBACT")` (CIANBLIS.m:139). `ACTD^CIANBACT`
  (CIANBACT.m:24-27) runs `RESET^CIANBRPC()` — the session logout/cleanup — then
  sets `CIADATA=1` and `CIAQUIT=1`. `CIAQUIT` makes the listener's `QUIT()`
  return true (CIANBLIS.m:151-152), so the loop ends and `TCPCLOSE` runs
  (CIANBLIS.m:114-117) instead of the retry drain. The broker replies to ACTD
  (`CIADATA=1` -> `REPLY`, CIANBLIS.m:142-143) and then closes.
- `RESET^CIANBRPC` quits unless `CIA("UID")` is set (CIANBRPC.m:102), and
  `DOACTION` only populates `CIA("UID")` from a `UID` field on the frame, so the
  quit frame carries the session UID exactly as an RPC frame does — otherwise the
  socket closes but the session's locks and `^XTMP` state never release.
- The close can win the race (CIAQUIT drops the socket the instant ACTD
  returns), so a peer-closed read or a broken-pipe write during the quit is the
  expected outcome of a clean disconnect, not an error, and is swallowed;
  `reset_connection` tears our side down regardless. A `disconnect` on a client
  that never connected still sends nothing.

Point 2 of #192 (`authenticate` returning `duz: nil`) was already resolved on
`main`: sign-on reads identity with `CIAVCXUS VIMINFO`, not `CIANBRPC GETVAR
"DUZ"`. `GETVAR^CIANBRPC` forces an empty or zero namespace to `"@"`
(`S:0[$G(NMSP) NMSP="@"`, CIANBRPC.m:187), while the sign-on DUZ is stored under
namespace `0` (RESET^CIANBRPC's ENVDATA loop), so that RPC can only ever return
`"DUZ="` with no digits — no regex could have matched it. The routine's output
shape is pinned by the `GETVAR_NO_DUZ_REAL` regression fixture. Point 3 (the
one-byte sequence echo in replies) is addressed in #289.

### Added — the gate can see line-based mappings at all (#190)

`Contract.mapping_kind` asked only `scalar?` / `text_blob?`, so the **19
registered mappings declared with `line_field`** — one field per LINE of
the reply, the sign-on and user-info reads among them — all classified as
`fields`. A capture of any of them would have compared line numbers
against caret-piece positions: the wrong axis, and silently, since both
are small integers. `kind: lines` was already an allowed fixture kind with
nothing behind it.

`DataMapper::Mapping` now exposes `line_fields` / `line_fields?`,
`mapping_kind` returns `"lines"` for them, and `Contract` gates them on
line position with a type check that reads lines rather than carets.
(Copilot, #190.)

### Fixed — the vitals capture cited the wrong ORQQVI tag (#190)

`orqqvi-vitals.yml` cited `VITALS^ORQQVI` and declared
`IEN^TYPE^DATETIME^value`. The #8994 registry serves "ORQQVI VITALS" from
**`FASTVIT^ORQQVI`** (dump line 565), whose header reads
`ien^type^rate^date/time taken` — pieces 3 and 4 are the reverse. The two
tags live in one routine and differ by that swap, which is how the
original mapping came to be "verified" against the wrong one.

Rebased onto `main` after #188 merged, so the gate now runs against the
corrected mapping. Consequences:

- The fixture cites FASTVIT and declares all seven pieces, including the
  IHS `MSR^ORQQVI` branch's display / metric-display / qualifiers.
- New `orqqvi-vitals-for-date-range.yml` keeps the `VITALS^ORQQVI` shape
  pinned to the RPC it actually belongs to, with its own limitation noted:
  that tag reads only GMRV #120.5 and has no `DUZ("AG")="I"` branch, so its
  IENs are not the V MEASUREMENT IENs the Measurement decoration expects.
- The `:problem_list` KNOWN_DIVERGENCES entry is gone — #188 fixed the
  mapping, the gate reports no divergence, and the entry left with the fix
  exactly as that list's contract requires.
- `test_gate_red_flags_the_fabricated_orqqvi_vitals_mapping` now expects
  three flagged positions, not four. Position 3 is a coincidence, not a
  pass: the invented layout happened to put a date where FASTVIT really
  carries one. Against the mis-cited fixture it read as a fourth catch,
  which flattered the gate.


### Removed — `Problem.filter` / `:problem_filter` were never bound to a problem list (#188)

The #8994 registry sends `BGOPROB GET CLASS` to **`DICLASS^BGOASLK`**
(`.broker_dumps_8994_20260607.txt:3103`), which is *"Get the
classifications for an asthma DX"* (BGOASLK.m:52-67):

- ONE param — `ICD ^ SNOMED ^ class type` (BGOASLK.m:53). It never took a
  DFN.
- Returns `""` outright unless `$$CHECK^BGOASLK` says the diagnosis is
  asthma (BGOASLK.m:58-60).
- Emits TWO-piece rows read out of `^APCDPLCL` (BGOASLK.m:65).

`:problem_filter` declared a ten-piece ORQQPL problem-list row over that
reply, and `Problem.filter(dfn, scope:)` called it with `(DFN,
scope_code)` using "IPL scope classes" `C`/`E`/`R`/`I` that appear
nowhere in the routine. A real reply (`"1^MILD INTERMITTENT"`) would have
parsed as a problem with no status — and an unrecognized status maps to
**active** downstream. The tests seeded problem-list-shaped rows into the
mock and asserted they came back, so the suite confirmed the fabrication
rather than catching it.

Retired whole, in the manner of the BHDPTRPC family (#174/#184), with the
real binding documented at the mapping site so it can be bound
deliberately — as an asthma-classification read — if a caller needs one.
`Problem.filter` and `Problem::SCOPE_CODES` are gone.

### Fixed — adversarial-gate findings on the measurement/provenance reads (#188)

- `FilemanDateParser.parse_datetime_or_date` no longer degrades an
  ILLEGAL time to midnight. `parse_date` keeps only the 7-digit prefix,
  so `"3260607.9"` (hour 90) used to come back as midnight on the 7th —
  and `Measurement#resolve_date` labels whatever it gets as the `:event`
  (clinical) time and stops looking, publishing a fabricated moment of
  care. A value carrying a time fraction now parses as a datetime or not
  at all.
- `Measurement.for_visit` / `.latest` / `.newest_by_type` return **nil**
  when the read FAILED (broker unreachable, or a `-N^message` error row)
  and `[]` only for no data. They previously collapsed both to `[]`, so
  "this patient has no recorded weight" and "we could not ask" were
  indistinguishable — the same collapse this work already fixed for
  `Patient.contact`. New `DataMapper::Mapping#fetch_many_or_nil` carries
  the distinction.
- `Measurement.latest` / `.newest_by_type` strip carets from every
  composed `INP` piece and require a numeric visit IEN. `types` and the
  date bounds were interpolated raw into a caret-delimited param, so a
  caller (or a FHIR `Observation?code=` query value) could inject extra
  protocol pieces: `latest(dfn, types: ["WT^INJECTED"], visit_ien: "9^9^9")`
  put six pieces on a three-piece wire.
- `Vital.add` no longer tells callers to recover saved measurement IENs
  via `Vital.for_patient`. That read is FASTVIT (newest-per-type), so a
  backdated save is simply absent from the reply and the match misses
  silently. Points at `Measurement.for_visit` instead.
- The `newest_by_type` fixture gave every row's DDR `.01` the default
  `"WT"`, so the test asserting both rows were `"WT"` matched the bad
  fixture and would pass even if the mapping ignored the row entirely.
  Each row now carries its own type, and the assertion is per row.

### Added — sign-on encryption and an atomic wire (#235)

- **`RpmsRpc.synchronize_wire` / `Client#synchronize_wire`** — reentrant lock
  serializing every request/reply pair (and multi-RPC sequences such as
  sign-on) on the shared broker client. New public API: consumers pinning the
  gem need `>= 0.3.0` for it to exist.
- **`Client#call_rpc_lines`** — reply LINES per each transport's reply
  grammar. Line-positional consumers (`DataMapper#line_field`) read through
  it; handing CIA's printable String to a line parser read framing bytes as
  fields (sequence echo `"2"` + ACK parsed as DUZ 2 / error 0 / success).

### Fixed

- **CIA sign-on binds `CIAV VUECENTRIC`, the application VueCentric signs on
  under,** instead of `CIANB MAIN MENU`. It is `CIANB MAIN MENU` whose RPC
  multiple carries just one RPC, so binding there left every call from a user
  without XUPROGMODE "Access denied" except the broker's own `CIANB*`
  routines; `CIAV VUECENTRIC` serves the set VueCentric actually calls. Captured from VueCentric's
  server-side activity log and verified live as PROV123 (cloud-rpms#55).
- **CIA sign-on reads the DUZ with `CIAVCXUS VIMINFO`,** the first identity
  read VueCentric makes after AUTH (piece 1 of its one-line reply). The
  previous read, `XUS GET USER INFO` (#251), is in no option sign-on binds,
  so it answered only users holding XUPROGMODE.
- `XUS AV CODE` / `XUS CVC` now cross the wire encrypted, per-RPC per the M
  source (`VALIDAV^XUSRB` decrypts the whole parameter; `CVC^XUSRB` splits on
  `^` first).
- Every failure path stays inside the wire lock: mid-write drops are typed
  `ConnectionError`s with the socket torn down, `IO::TimeoutError` gets the
  timeout teardown, CIA post-timeout recovery no longer resets a connection
  it no longer owns, `create_context` commits under the lock, and public
  receive methods can no longer consume another caller's in-flight reply.

### Fixed — AGG delegation never fired: the gate was asked in the wrong context (#225)

`Registration.register` gated delegation on `Agg.available?`, but **nothing on
that path ever bound the AGGRPC context**. RPC registration is OPTION-scoped —
`CANRUN` answers from the RPC multiple of the option bound right now
(`CIANBACT.m:148,155`) — and the AGG* RPCs are registered under AGGRPC alone
(`^DIC(19,13112,0)="AGGRPC^Patient Registration GUI^^B^…"`, with AGG ADD NEW
PATIENT / 8994 IEN 3374 at `^DIC(19,13112,"RPC","B",3374,20)`). They are absent
from both contexts this gem can be sitting on: **CIANB MAIN MENU** (#10976, what
CIA sign-on binds — no RPC multiple at all) and **OR CPRS GUI CHART** (#9649,
1004 RPCs, no 3374). So on any non-privileged session the gate was answered a
truthful 0, delegation silently never fired, and every registration fell back to
the VOA + DDR composition — skipping the AG capsule's HL7/MPI staging, the
`^AGPATCH` stamp and the edit-check rules that delegation exists to inherit. A
session holding `XUPROGMODE` cannot see this: the bypass (`CIANBACT.m:147`)
answers 1 either way.

- **New `RpmsRpc::ContextScope`** (`current_context` / `with_context`), included
  by `Client` and `MockClient`. `with_context` binds an option, runs the block
  and restores the caller's — no round trip when it is already bound, so
  nesting is free.
- **`RpmsRpc::Agg` binds its own context.** `available?`, `add_patient`,
  `update_patient` and `edit_check` all scope to `Agg::CONTEXT` ("AGGRPC")
  rather than telling callers to do it. Deliberate: leaving the bind to the
  caller is what made "not runnable HERE" indistinguishable from "AG not
  installed".
- **`CiaClient#create_context` now binds the CIA-native way — no round trip.**
  CIA carries the context as a **CTX field on the RPC frame**
  (`CIANBLIS.m:165,168` → `CIA("CTX")`; `CIANBACT.m:50,55`), so a switch is a
  client-side state change, not an `XWB CREATE CONTEXT` call — which, being
  `CRCONTXT^XWBSEC` (a non-`CIANB*` routine), would itself have to be
  registered to the option currently bound in order to change it. Sign-on binds
  `CIANB MAIN MENU` as the session AID (`CIANBRPC.m:22,27,62`), which the
  client now tracks. **Frames are byte-identical to before until something
  binds a context**; from the first bind onward every frame carries CTX,
  because ACTR persists the last CTX it saw and reuses it when a frame omits
  one — a restore that stopped naming the context would be a no-op.
- **Fail-safe, and now loud.** A context that will not bind, a "0" answer, an
  empty reply or an `RpcError` all return false and `warn` before composing
  VOA + DDR. Scoping a session with no declared context warns too: there is no
  "unbind", so it cannot be undone.

Live verification against a **non-privileged** session is still owed — #224.

### Corrected provenance — `CIANBRPC CANRUN` takes the RPC NAME (#225)

`Agg.available?` was reported as passing an RPC name to a gate that wants a
file-8994 IEN, which would have made AGG delegation fail closed for every
non-privileged session. **The M source says otherwise and no behavior
changed.** The registered entry is `"CIANBRPC CANRUN^CANRUN^CIANBRPC^1"`, so
the wire entry point is `CANRUN^CIANBRPC`, which resolves the IEN itself —
`S DATA=$$CANRUN^CIANBACT($$FIND1^DIC(8994,,"QX",RPC),CIA("CTX"))`
(`CIANBRPC.m:173-175`). Only the inner `CANRUN^CIANBACT` helper takes an IEN.
Passing the name is correct; passing an IEN would be the defect.

- `Agg::CANRUN_RPC`, the `Agg` wire-contract table and the `:agg_canrun`
  mapping comment now cite `CANRUN^CIANBRPC` (they said `CANRUN^CIANBACT`,
  the inner helper — the mislabel that produced the report).
- `Agg.available?` documentation now carries the full derivation, the two
  preconditions that legitimately answer 0 (the gate is per **context
  option**, and the context check at `CIANBACT.m:145` runs *before* the
  `XUPROGMODE` bypass at `:147`, so an un-contexted session is answered 0
  even for a programmer), the honest statement that a privileged session
  cannot prove the gate either way, and the fail-safe rationale for the
  VOA + DDR fallback.
- Regression tests pin the wire argument as the RPC **name** and prove a
  gate keyed on anything else does not satisfy the probe.

Live verification against a **non-privileged** session is still owed — that
is #224.

### Fixed (BGO write APIs rebound to the real writers — #217)

Four write APIs were bound to wrong-semantics RPCs; three silently faked
success and one filed wrong clinical data. All rebound against the FOIA M
source with the INP layouts each routine actually parses:

- `Problem.add/update` now call **BGOPROB SET** (SET^BGOPROB) with the
  "P"-line ARRAY contract; `Problem.delete` calls **BGOPROB DEL**. The old
  binding, BGOPROB1 EDPROB, is a *read* ("Get active problems") — writes
  were silently dropped while the API parsed a returned problem IEN as a
  "saved" IEN. **Breaking:** the problem hash is now the BGOPROB "P"-line
  contract (`PROB_FIELDS`: `:snomed_ct, :descriptive_ct, :description,
  :icd_code, :location_ien, :onset_date, :status, :problem_class,
  :problem_number, :priority`); `:location_ien` is required by the M side
  (-1049 without it). `EDIT_ACTIONS`/`EDPROB_FIELDS` removed.
- `Pov.add` → **BGOVPOV SET**, `HealthFactor.add` → **BGOVHF SET**,
  `ExamComponent.add` → **BGOVEXAM SET**, `Measurement.add` →
  **BGOVMSR SET**. The old shared binding BGOVUPD SET writes V
  UPDATE/REVIEWED (#9000010.54) — none of the four visit-data entries were
  ever filed. **Breaking:** `Measurement.add`'s `units:`/`qualifier:` are
  no longer transmitted (BGOVMSR SET has no such pieces — units are fixed
  by the measurement type); `Pov.add` modifier `:fraction` is now
  `:fracture`; `HealthFactor.add` gains `provider_duz:`/`quantity:`;
  `ExamComponent.add` gains `provider_duz:`.
- `ImmunizationRefusal.record` → **BGOREF SET** with refusal type
  "IMMUNIZATION" (the ^AUPNPREF personal-refusals writer). The old binding
  BGOREP SET writes *reproductive history* (^AUPNREP) — and BGOREF/BGOREP
  were swapped with the referral finding below. **Breaking:** signature is
  now `record(dfn, vaccine_ien, reason_ien:, narrative:, refusal_date:,
  provider_duz:)`; the invented `REASON_CODES` letter table is removed —
  reasons are REFUSAL REASON (#9999999.102) IENs, listed by the new
  `ImmunizationRefusal.reasons`. Success returns no IEN (the M API returns
  "" on success); broker silence is a failure, not a success.
- `Referral.create` is now honestly **`:not_implemented`**: BGOREF SET
  files refusals, and the real referral writer (BMC ADD REFERRAL =
  SETREFRL^BMCRPC2, 39 positional formals) cannot be faithfully driven
  from `create`'s small hash — use `Referral.add` with the full RCIS
  parameter list. `CREATE_FIELDS` removed.
- Mappings: `:problem_edit`, `:visit_data_save`, `:referral_create`,
  `:immunization_refusal_save` removed; `:problem_set`, `:problem_remove`,
  `:pov_set`, `:health_factor_set`, `:exam_set`, `:measurement_set`,
  `:refusal_set`, `:refusal_reasons` added.

### Fixed (clinical reads feeding FHIR — #218)

- `:problem_list` (ORQQPL LIST) columns corrected to the real wire
  (IEN^NARRATIVE^STATUS^ICD^ONSET^LASTMOD^SC^SPEXP — ORQQPL.m:14 over
  GMPLUTL3.m:120). **Breaking:** `:status`/`:description` positions were
  swapped; `:recorded_date` (really date-last-modified) is now
  `:last_modified`; `:provider_duz` (really the SC/NSC flag) is now
  `:service_connected`; `:special_exposure` added.
- `:vitals` (ORQQVI VITALS) columns corrected (IEN^TYPE^DATETIME^RATE —
  ORQQVI.m:6,23). **Breaking:** `:type` no longer carries the IEN (new
  `:ien` field), `:value` carries the rate (was the type name),
  `:recorded_date` the datetime (was the numeric value); `:units` removed —
  there is no units piece on this wire.
- `:medication_list` (ORQQPS LIST) columns corrected
  (ID^NAMEFORM^STOPDATE^ROUTE^SCHEDULE^REFILLS — ORQQPS.m:5,47).
  **Breaking:** `:sig`/`:status`/`:last_fill`/`:provider` removed (no such
  pieces exist); `:stop_date`/`:route`/`:schedule` added.
- `:allergy_list` (ORQQAL LIST) columns corrected
  (IEN^AGENT^SEVERITY^SIGNS — ORQQAL.m:8,14,18-21). **Breaking:**
  `:allergen` no longer carries the IEN (new `:ien` field), `:reaction`
  removed (it was the agent duplicated); `:signs` added (";"-joined
  signs/symptoms).
- `DataMapper` parse guard: broker error rows (`-N^message`) and no-data
  sentinel rows (`^message` — "^No problems found.", "^No Allergy
  Assessment", "^No Known Allergies", "^No vitals found.",
  "^No medications found.", …) never surface as data records from
  `parse_one`/`parse_many`. Mappings that legitimately model status/error
  replies opt out with `status_reply!` (`:voa_add_patient`,
  `:patient_lock`, `:immunization_exchange_status`).
- `Patient.find` returns `nil` for an unknown DFN instead of a phantom
  `{name: "-1"}` record (SELECT^ORWPT's `-1^^^^^Patient is unknown to
  CPRS.` — ORWPT.m:49).

### Added

- Wire-shape contract gate (#189): `RpmsRpc::WireCapture` +
  `rake wire:capture` capture curated RPC returns from a rung we own into
  provenance-stamped fixtures (`test/fixtures/wire_captures/` — verbatim
  raw + sha256 for live captures, M-source cites for write/faulting RPCs;
  a fixture with neither provenance is rejected), and
  `test/rpms_rpc/wire_contract_test.rb` gates every mapping with a
  committed capture in CI: declared field positions must carry the cited
  wire semantics and typed fields must survive the captured raw. Closes
  the belief-mirroring-mock failure class (ORQQVI VITALS shipped
  `TYPE^VALUE^UNITS^DATE` against a real wire of `IEN^TYPE^DATETIME^value`
  and stayed green); on its first run the gate caught `:problem_list`
  (status/description swapped, phantom provider-DUZ piece) and
  `:patient_id_info` (position 3 is the VETERAN flag, not a race code;
  position 5 the ward, not a site IEN) — pinned as known divergences for
  their own mapping-fix PRs. See docs/WIRE_CONTRACTS.md.

- `RpmsRpc::Allergy.assessment(dfn)` — three-state allergy result
  `{ assessed:, nka:, allergies: [] }` so consumers (FHIR
  AllergyIntolerance) can distinguish assessed-no-known-allergies from
  not-assessed. `Allergy.for_patient` keeps the record-array shape and
  yields `[]` for both empty states.

The invented BHDPTRPC placeholder namespace is now fully removed
(issues #174/#184: zero hits across the 65,782-routine FOIA corpus, the
staging file-8994 fingerprint, and IHS public RPC docs), and patient
registration now delegates to the IHS AG package when it is present,
composing verified stock-VistA RPCs otherwise. Live round-trip
verification is gated on the rpms-ops evidence run (contracts: rpms-ops
`docs/REGISTRATION_RPC_CONTRACTS.md`).

### Added

- `RpmsRpc::Registration.update` / `Patient.update` — composed patient
  edit: `DDR FILER` (`FILE^DIE`, internal values) for PATIENT (#2) and
  IHS PATIENT (#9000001) fields under the same `^DPT(DFN)` lock
  `EDIT^VAFCPTED` takes. The VA edit routine itself has no `^XWB(8994)`
  registration on any observed target, so the registered generic filer
  is the edit path.
- `RpmsRpc::Encounter.create` — visit get-or-create over the registered
  `BEHOENCX FETCH` with its CREATE flag (`-1` always / `0` never / `1`
  if-not-found); creation descends to `GETVISIT^BSDAPI4`, the IHS PCC
  visit-creation API. `GETVISIT^BEHOENCX` is a pure fetch and never
  creates (rpms-ops `docs/REGISTRATION_RPC_CONTRACTS.md` §3). Reply
  layout is source-derived (`:encounter_get_or_create`); live capture
  pending.
- `RpmsRpc::Tribal.tribes` — tribe list via `DDR LISTER` over the TRIBE
  (#9999999.03) "B" index.

- `RpmsRpc::Agg` — the AG-package GUI registration RPC surface
  (`AGG ADD NEW PATIENT` = `ADD^AGGPTADD`, `AGG UPDATE PATIENT` =
  `UPD^AGGPTUPD`, `AGG PATIENT EDIT CHECK` = `CHK^AGGEDCHK`), context option
  `AGGRPC`. Request framing is P1 window name / P2 DFN / P3 `$C(28)`-delimited
  `NAME=VALUE` PARMS; the reply is a GLOBAL ARRAY (typed header row, then
  `$C(30)`-separated records, `$C(31)` end sentinel). `Agg.available?` gates
  delegation on real registry evidence — `CIANBRPC CANRUN "AGG ADD NEW
  PATIENT"` — which reports RPC presence WITHOUT executing the write RPC
  (rpms-rpc#209/#214). Wire layouts capture-verified live on bcer-9.0-ydb.
- `CiaClient#call_rpc_global_array` — reads a GLOBAL ARRAY (return type 4)
  reply to its `$C(31)` sentinel. The default read stops at the first EOD,
  which for AGG replies is the header's embedded `$C(30)` record separator
  (== the CIA EOD), truncating the data records.
- `RpmsRpc::Registration` delegation lineage — when `Agg.available?`,
  registration calls `AGG ADD NEW PATIENT` / `AGG UPDATE PATIENT`, inheriting
  the AG capsule's HL7/MPI staging, `^AGPATCH` register stamp and
  edit-check completeness rules instead of reimplementing them.
- `RpmsRpc::Registration` composition lineage (the lineage-portable floor for
  civilian/stock VistA with no AG package): `VAFC VOA ADD PATIENT` (PATIENT
  #2 half, returns the DFN) then `DDR LOCK/UNLOCK NODE` + `DDR GETS ENTRY
  DATA` (idempotent-re-run existence probe) + two `DDR FILER` passes (the
  #9000001 stub at the DINUM IEN = DFN, then the HRN 41-multiple entry and

- `RpmsRpc::Measurement.find` — one V MEASUREMENT by IEN via
  `DDR GETS ENTRY DATA` on #9000010.01 (field numbers cited from corpus
  readers: .02 patient DFN — APCDBMI.m:20; .03 visit — APCDBMI.m:22 /
  BHSMEA.m:87; .04/1201/2 — the exact set BTIUPCC4.m:19 reads; .01 type
  whose external form is the abbreviation — BEHOVM2.m:65-66), decorated
  with service category / capture mode / units like `.for_visit`. Returns
  `:patient_dfn` so id-addressed FHIR lookups (Provenance target search)
  can resolve the patient from a measurement IEN alone.
- `RpmsRpc::Measurement.newest_by_type` — the patient's newest
  measurement per vital type (optional FileMan date range) via
  `ORQQVI VITALS`, each row decorated per measurement via the `.find`
  DDR read + `BEHOENCX GETVISIT` + `BEHOVM2 VUNITS` (memoized).
  Decoration degrades to nil fields (`capture_mode: :unknown`,
  `entered_in_error: nil`, `units: nil`) — unknown is reported as
  unknown, never fabricated. This replaces a briefly-added `.history`
  method whose "full patient history" claim was false: the registered
  `ORQQVI VITALS` dispatches to FASTVIT^ORQQVI (newest-per-type only).
  No registered RPC currently provides a verifiable full V MEASUREMENT
  history (see the `:vitals_for_date_range` mapping notes), so the gem
  does not pretend to one.
- Rows from the `Measurement` reads now carry `:date_source` labeling the
  clinical-date provenance — `:event` (#9000010.01 field 1201, the taken
  time the writer files — BEHOENPC.m:275,286), `:visit` (1201 empty →
  the visit's own date, the canonical readers' fallback — BPXRMPX.m:60-64,
  BGOVMSR.m:29), or `:entered` (only .07 TIME ENTERED available — an
  administrative save timestamp (BEHOENPC.m:274,287; BPXRMPX.m:70),
  surfaced labeled instead of silently substituted for clinical time).

- `RpmsRpc::Measurement.for_visit` / `.latest` — measurement reads that
  carry FHIR-Provenance signals, composed entirely from existing
  registered RPCs (no new M): `BGOVMSR GET` / `BGOVMSR LAST` (rows with
  the visit IEN — GET/LAST^BGOVMSR), `BEHOENCX GETVISIT` (the visit's
  SERVICE CATEGORY, #9000010 field .07 — GETVISIT^BEHOENCX),
  `DDR GETS ENTRY DATA` (#9000010.01 field 2 ENTERED IN ERROR — the flag
  `EIE^BEHOVM2` stores and `BLDXRF^BEHOVM` filters on — plus the internal
  1201/.07 date/time), and `BEHOVM2 VUNITS` (display units for the raw
  US-unit stored value). Each row:
  `{ type:, value:, units:, date:, date_display:, measurement_ien:,
  visit_ien:, service_category:, capture_mode:, entered_in_error:, ... }`
  with `capture_mode` classifying the service category
  (A/H/I/S/O/R/D → `:office`, T/M/E/C → `:reported`, else `:unknown` —
  code set cited from PXRHS01.m:14-26 and APCDEIN.m:85). Note
  `BGOVMSR GET`/`LAST` do NOT filter entered-in-error rows (unlike the
  BEHOVM query path), which is why the explicit flag is part of the read.
- `RpmsRpc::Patient.contact` — patient telecom
  (`phone_home`/`phone_work`/`phone_cell`/`email`, PATIENT #2 fields
  .131/.132/.134/.133) via the registered generic FileMan read
  `DDR GETS ENTRY DATA`. The full corpus×registry sweep of
  `^DPT(*,.13)` readers found no registered purpose-built structured
  alternative: `BEHOPTCX PTINFO1` has exactly these fields but is not
  in the #8994 registry; `DGRR GET PATIENT SERVICES DATA` (XML) and
  `BQI MAIL MERGE LIST` / `VEN ASQ GET DATA` carry only subsets in
  awkward envelopes; nothing purpose-built serves the cellular phone.
- Mappings `:visit_measurements`, `:latest_measurements`, `:vital_units`;
  `:encounter_visit` now exposes `:service_category` (verified reply
  piece 3 — GETVISIT^BEHOENCX header), `:visit_id` (piece 5 is the visit
  id, not a ward) and `:locked`, keeping `:status`/`:ward` as legacy
  aliases. `DataMapper#format_one` supports aliased positions (an
  unseeded alias no longer blanks a seeded one).

- `RpmsRpc::Registration` — patient registration composed from verified
  stock-VistA RPCs: `VAFC VOA ADD PATIENT` (PATIENT #2 half, returns the
  DFN) then `DDR LOCK/UNLOCK NODE` + `DDR LISTER` (HRN "D"-xref
  uniqueness pre-check) + `DDR GETS ENTRY DATA` (idempotent-re-run
  existence probe) + two `DDR FILER` passes (the #9000001 stub at the
  DINUM IEN = DFN, then the HRN 41-multiple entry and
  tribe/community/classification/eligibility fields). Explicit error
  taxonomy: `:voa_rejected` / `:duplicate_identity` / `:lock_failed` /
  `:filer_rejected` (composition), `:agg_rejected` / `:hrn_file_failed`
  (delegation). Every wire shape cites its M routine (bcer-9.0-ydb corpus).

### Changed

- HRN handling (rpms-rpc#214): the client no longer assigns or enforces
  HRNs. `Registration.hrn_mode` selects the policy. The greenfield default
  `:derive_from_dfn` sets **HRN := DFN** — FileMan's IEN allocation is the
  server-side atomic assigner, so the HRN is unique by construction with no
  client logic and no race. The legacy `:clerk_supplied` mode files the
  caller-supplied HRN as a plain passthrough. **The client-side HRN "D"-xref
  uniqueness pre-check (`DDR LISTER`) has been removed** — no client-side HRN
  validation remains in either mode. A server-held claim sequence
  (`DDR LOCK` → all-holders D-xref walk → `DDR FILER` → unlock, in one broker
  session) is documented follow-up for the clerk-supplied mode (#214), not
  this change.
- `RpmsRpc::DdrFileman` — wrapper for the FileMan Delphi Components RPC
  family (`DDR FILER` / `DDR LISTER` / `DDR LOCK/UNLOCK NODE` /
  `DDR GETS ENTRY DATA` / `DDR VALIDATOR`) with public request builders
  and reply-grammar parsers.
- `CiaClient` list params: `Hash` params encode as named-subscript
  NAME/SUBSCRIPT/VALUE triples (string subscripts M-quoted, numeric bare
  — the raw-splice contract of DOACTION^CIANBLIS), `Array` params as
  1-based numeric subscripts; matches `XwbClient`'s public param
  convention.

### Fixed

- `:problem_list` (`ORQQPL LIST`) declared a fabricated row shape —
  STATUS and DESCRIPTION swapped, and RECORDED_DATE / PROVIDER_DUZ
  invented at pieces 6-7. Verified wire (LIST^ORQQPL: ORQQPL.m:3-18,
  reshuffling the LIST^GMPLUTL3 row — GMPLUTL3.m:76-124) is
  `IEN^NARRATIVE^STATUS^ICD^ONSET^LAST MODIFIED^SC^SPEXP^TRANSCRIBED^PRIORITY^^DETAIL`
  with STATUS = #9000011 field .12 internal (`"A"`/`"I"`). Under the old
  mapping a real inactive row put the narrative text into `:status`, so
  downstream FHIR mappers defaulted the unrecognized value to "active".
  `Problem.for_patient` now also drops the `"^No problems found."`
  sentinel row (ORQQPL.m:17). `:problem_filter` (`BGOPROB GET CLASS`) is
  **retired** rather than redeclared — see below.
- `:vitals` (`ORQQVI VITALS`) — fixed TWICE, and the second fix is the
  lesson. The original mapping matched an invented `TYPE^VALUE^UNITS^DATE`
  shape. The first correction read a plausibly-named tag
  (VITALS^ORQQVI) and declared `IEN^TYPE^DATETIME^VALUE` — but the #8994
  registry dispatches "ORQQVI VITALS" to **FASTVIT^ORQQVI**
  (`.broker_dumps_8994_20260607.txt:565`), whose rows are
  `IEN^TYPE^VALUE^DATETIME` (header ORQQVI.m:66-67; rows ORQQVI.m:113/
  179) — value and date were swapped, and the RPC returns only the
  NEWEST value per type, not history. The shape the first fix declared
  belongs to a different RPC, "ORQQVI VITALS FOR DATE RANGE"
  (dump line 795), now declared as `:vitals_for_date_range` with its
  GMRV-#120.5-only limitation documented. Method: resolve the registry
  name→tag mapping FIRST, then read that exact tag's return
  construction — grepping a routine for a plausible tag finds the wrong
  entry point. `Vital.for_patient` documents newest-per-type semantics,
  takes an optional date range, and guards invalid DFNs; FASTVIT emits
  no sentinel (that belongs to VITALS^ORQQVI), but IEN-less rows are
  still dropped defensively. `:fileman_datetime` coercion now always
  yields a `Time` (midnight for date-only values) instead of sometimes
  `Time`, sometimes `Date`.
- `:medication_list` (`ORQQPS LIST`) declared a fabricated
  `IEN^DRUG_NAME^SIG^STATUS^LAST_FILL^REFILLS^PROVIDER` shape. Verified
  wire (registry dump line 576 → LIST^ORQQPS: ORQQPS.m:4-55, header
  ORQQPS.m:5) is `ID^NAME^STOP_DATE^ROUTE^SCHEDULE(or infusion
  rate)^REFILLS(outpatient only)` — no SIG/STATUS/PROVIDER pieces exist.
  `Medication.for_patient` drops the `"^No medications found."` sentinel
  (ORQQPS.m:53) and guards invalid DFNs.
- `DdrFileman.gets_entry` reports a reply with no parsed rows and no
  `[Data]` marker as an error (broker error strings like `-1^...` match
  neither), so `Measurement` EIE reads degrade to `nil`/unknown and
  `Patient.contact` returns `nil` instead of fabricating
  `entered_in_error: false` / "no telecom on file" from a failed read.
- `Problem.for_patient` / `Vital.for_patient` / `Medication.for_patient`
  short-circuit nil/blank/non-positive DFNs to `[]` without dispatching
  an RPC.
- `client.rb` requires `rpms_rpc/version` so a standalone
  `require "rpms_rpc/cia_client"` (how the release evidence drivers load
  the gem) keeps `RpmsRpc.sanitize_error`: without it every client error
  path raised `NoMethodError` instead of the real broker error (observed
  live against rpms-ydb-9.0).
- `CiaClient#authenticate` now requests session UID `0` on first sign-on
  (was hard-coded `"1"`). `AUTH^CIANBRPC` treats a non-zero UID as a
  reconnect to that session; on any box with an existing session #1 it
  failed "reconnection attempt for session #1 has failed. The session was
  authenticated for a different user.", bound no DUZ and no context, and
  every gated RPC then returned "Access denied for remote procedure." UID
  `0` makes the broker allocate a fresh session (`CIANBRPC.m:58-59`) whose
  UID the client now adopts and carries on later frames.

### Changed

- `Patient.register` now delegates to `Registration.register`; failures
  return `{ success: false, error: Symbol, message: String }` instead of
  `error: String`.
- `RpmsRpc::Tribal` reads now run on `DDR GETS ENTRY DATA` /
  `DDR VALIDATOR` over the real files (#9000001 tribal fields verified
  against the AG field maps and the live DD; TRIBE #9999999.03; SERVICE
  UNIT #9999999.22). Semantics narrowed to what the server actually
  offers: `enrollment`/`eligibility` project internal/external field
  pairs (the invented `:active`/`:eligible_for_ihs`/`:benefit_package`/
  `:region` keys are gone); `validate` is input-transform validation of
  the enrollment number (#9000001 field .07) — no server-side
  membership check exists; `service_unit`/`tribe_info` take table IENs
  instead of a DFN/code.

### Removed

- The entire `BHDPTRPC` placeholder namespace. Earlier: the `REGISTER`
  mapping and its single-caret-param contract
  (`Patient.registration_param`). Now: the remaining seven wire names
  and mappings — `TRIBAL`, `TRIBALVAL`, `TRIBELIST`, `TRIBALELG`, `SU`
  (`:tribal_enrollment`, `:tribal_validation`, `:tribe_info`,
  `:enrollment_eligibility`, `:service_unit` caret forms), `UPDATE`
  (`:patient_update`), and `NEWVISIT` (`:encounter_create`). The
  namespace was invented and never had a server implementation anywhere
  (docs/RPC_COVERAGE.md provenance notes; issues #174/#184).

## [0.2.0] — 2026-09-01

CIA client wire-behavior corrections (#178, #179, #180, #177). Public API
kept compatible.

### Added

- `RpmsRpc::Client::RpcTimeoutError` — raised when a single RPC's reply
  times out mid-call. Subclass of `TimeoutError` (and so
  `ConnectionError`), so existing rescue blocks keep working; the client
  closes the socket first (a `{CIA}` reply abandoned mid-read cannot be
  resynchronized), so callers reconnect and re-authenticate rather than
  retrying on a corrupted stream. (#178)
- `CiaClient#authenticate` populates `duz` at sign-on via the
  context-exempt `CIANBRPC GETVAR`, and captures the broker-assigned
  session UID for later calls. (#178)

### Fixed

- `CiaClient` sequence byte cycles 1–9 so the fixed-width `{CIA}` header
  survives ten or more exchanges on one connection. (#179)
- A failed CIA connect handshake closes the socket and resets to a
  defined disconnected state instead of leaking the open socket behind a
  retried connect. (#178)
- `ESignature` sends the verified TIU/ORWU wire shapes: the signature
  code crosses the wire XWB-encrypted, the signer rides the
  authenticated session DUZ (never the wire), `remove` dispatches
  `TIU DELETE RECORD`, and `action: :addend` raises `ArgumentError`
  rather than mis-signing. (#180)
- `DataMapper::Mapping#parse_many` no longer crashes on a bare String
  where a list was expected; a broker `-1^message` error string yields
  no rows instead of a bogus record parsed from the error text. (#177)

## [0.1.0] — 2026-04-07

Initial release. Pure Ruby RPC client extracted from the predecessor Rails app.

### Added

- `RpmsRpc::Client` — abstract broker base class with connection
  lifecycle, XUS signon authentication, XWB cipher encryption
  (`xwb_encrypt` matching `$$ENCRYP^XUSRB1`), and socket helpers.
- `RpmsRpc::CiaClient` — XWB/CIA wire protocol on port 9100,
  per FOIA-RPMS XWBTCPM.m.
- `RpmsRpc::BmxClient` — BMX wire protocol on port 9200,
  per FOIA-RPMS BMXMON.m / BMXMBRK.m.
- `RpmsRpc::ParameterEncoder` — VistA `1{len}00f{value}\x04`
  parameter encoding with `ParameterTooLongError` at 999 bytes.
- `RpmsRpc::ResponseParser` — caret-delimited response parser
  with `RpcResult` struct and `pick_string` / `pick_value` /
  `piece` / `pipe_piece` / `pipe_param` helpers.
- `RpmsRpc::XmlResponseParser` — REXML-based parser for VistA
  RPC XML responses (`Gov.VA.Med.RPC.Response` and
  `VA.RPC.Error`).
- `RpmsRpc::FilemanDateParser` — bidirectional conversion between
  Ruby `Date`/`Time` and FileMan `YYYMMDD.HHMM` (year - 1700).
- `RpmsRpc::PhiSanitizer` — HIPAA-aligned scrubbing for log
  messages and hashes; HMAC-SHA256 identifier hashing with a
  12-character display prefix.
- ADR 0001 — Scope and no Rails coupling.
- ADR 0002 — Verified routine policy (every shipped RPC must
  be verified against MUMPS source in CIVITAS FOIA-RPMS).
- `docs/rpcs.md` — verified RPC audit trail.

### Notes

- Requires Ruby 3.4+.
- Runtime dependency: `rexml ~> 3.2` (default gem in 3.4+ but
  must be declared so Bundler puts it on the load path).
- No Rails dependency. No ActiveSupport on the load path.
- Test suite is hermetic — 116 tests, no sockets, no live RPMS.
