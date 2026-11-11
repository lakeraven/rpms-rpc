# ADR 0011: The VueCentric-only RPCs the gem keeps

**Status:** Proposed
**Date:** 2026-11-11
**Relates to:** rpms-rpc#528, #527 (problem list), #524 (psych CPT), #645 (the encounter write), [docs/vuecentric-exit.md](../vuecentric-exit.md)

## Context

rpms-rpc signs on as the VueCentric application and binds `CIAV VUECENTRIC`.
Some of the RPCs it sends are registered in that broker option and in no other.
A web client that keeps them stays tied to VueCentric's option, so each one should be kept on purpose, with its reason written down.

`docs/vuecentric-exit.md` is the analysis: what each need is, which stock routes exist, and how they compare.
This ADR is the short list that analysis feeds: which VueCentric-only RPCs the gem keeps today, and why.

The list is computed, not kept by hand: an RPC is on it when `lib/rpms_rpc/required_rpcs.json` names it and the build's broker-option inventory (`data/inventories/<build>/<build>-contexts_19_05.txt`, the build `required_rpcs.json` names) lists it in `CIAV VUECENTRIC` only.
On `bcer-9.0-20261012-e7923a4-ydb` that is 41 RPCs.

## Decision

1. The gem keeps the 41 RPCs below. Each row names the module that sends it, why no stock route is used yet, and the route that would replace it.
2. A VueCentric-only RPC is added to the gem only with a row here, in the same change. `test/rpms_rpc/vuecentric_only_rpcs_test.rb` fails when `required_rpcs.json` gains one this table does not list, and when the table lists one that is no longer VueCentric-only or no longer sent.
3. The problem-list writes and the psych CPT are decided, not pending: problem writes stay on `BGOPROB SET` / `BGOPROB DEL` (#527), and the CPT is filed through `BEHOENPC SAVE` (#524). Both are live-proven.
4. Leaving one of these for a stock route takes its own change: the stock route proven live, the RPC gone from `required_rpcs.json`, and its row deleted.
5. Each of these RPCs binds its own option. Its mapping declares it (`m.context VUECENTRIC` in `lib/rpms_rpc/mappings/ihs.rb`), and DataMapper sends the call under that option and restores the caller's (`ContextScope.scoped`), so the RPC answers whichever option the session has bound. On a CIA session, already bound to `CIAV VUECENTRIC` by sign-on, that costs nothing. The test fails when a VueCentric-only RPC's mapping declares no option, and `test/live/vuecentric_only_context_live_test.rb` proves the bind on the pinned build.

| RPC | Used by | Why no stock route yet | Replacement path |
|---|---|---|---|
| `BEHOCCD GETREF` | `RpmsRpc::Phr` | PHR and C-CDA reads; no stock RPC outside `CIAV VUECENTRIC` serves them. | None planned for December; the C-CDA is built in Rails. |
| `BEHOCCD PHR` | `RpmsRpc::Phr` | As above. | As above. |
| `BEHOCIR GETNUM` | `RpmsRpc::Phr` | As above. | As above. |
| `BEHOCIR1 GETCCDS` | `RpmsRpc::Phr` | As above. | As above. |
| `BEHOENCX CHKVISIT` | `RpmsRpc::Encounter` | The visit-context calls VueCentric makes; the stock routes that create a visit are package writes, not yet verified on a running image. | `BSDX CHECKIN APPOINTMENT` (creates the visit when the clinic's flag is set) or `AMHG SAVE VISIT` for BH. |
| `BEHOENCX FETCH` | `RpmsRpc::Encounter`, `RpmsRpc::Scheduling` | As above. | As above. |
| `BEHOENCX GETVISIT` | `RpmsRpc::Encounter`, `RpmsRpc::Measurement` | As above. | As above. |
| `BEHOENCX VISITLST` | `RpmsRpc::Encounter` | `VISITLST^BEHOENCX` lists the patient's visits with the IHS lock flag (`ISLOCKED^BEHOENCX`), the primary provider and a standalone flag, then appointments pending check-in (`SDA^VADPT`). `ORWCV VST` and `ORQQVS VISITS/APPTS` (`OR CPRS GUI CHART`) list visits and appointments without those fields. Not compared live. | `ORWCV VST` plus a DDR read of VISIT for the lock and provider, unverified. |
| `BEHOENPC SAVE` | `RpmsRpc::Procedure` | Files the visit and its V files in one call. `ORWPCE SAVE` is registered to `SAVE^CIAVCXPC`, which the build does not carry (rpms-ops#1042). Decided for the psych CPT (#524). | None outside `CIAV VUECENTRIC`. |
| `BEHOPTPC GETBDP` | `RpmsRpc::Patient` | Designated provider. `ORWPT1 PRCARE` reads PCMM, which IHS sites do not fill. | DDR read of IHS PATIENT (#9000001) .14. |
| `BEHOPTPL DOBLKP` | `RpmsRpc::PatientSelection` | VueCentric's patient lookups; behaviour not compared with a stock lookup. | `AGG LOOKUP PATIENTS` (`AGGRPC`), a candidate. |
| `BEHOPTPL HRNLKP` | `RpmsRpc::PatientSelection` | As above. | As above. |
| `BEHOPTPL LISTALL` | `RpmsRpc::PatientSelection` | As above. | As above. |
| `BEHOPTPL LOOKUP` | `RpmsRpc::PatientSelection` | As above. | As above. |
| `BEHOSICX SITEINFO` | `RpmsRpc::Site` | A stock route exists and is not switched to yet. | `XUS GET USER INFO` line 3 and `XUS DIVISION GET`. |
| `BEHOVM SAVE` | `RpmsRpc::Vital` | Vitals; the GMV vitals RPCs are not checked. | `AMHG SAVE MEASUREMENTS` for BH; GMV for the rest, unverified. |
| `BEHOVM TEMPLATE` | `RpmsRpc::Vital` | As above. | As above. |
| `BEHOVM VALIDATE` | `RpmsRpc::Vital` | As above. | As above. |
| `BEHOVM2 VUNITS` | `RpmsRpc::Measurement` | As above. | As above. |
| `BEHOXQ ALRLIST` | `RpmsRpc::Notifications` | `ALRLIST^BEHOXQ` reads the user's alerts (`^XTV(8992)`) and runs each alert's IHS handler (BEHOXQ file 90460.021) for its priority, type and patient. `ORWORB FASTUSER` (`OR CPRS GUI CHART`) lists the alerts without those handler fields. | `ORWORB FASTUSER`, if the handler fields can be dropped or rebuilt. |
| `BEHOXQ ALRMSG` | `RpmsRpc::Notifications` | `ALRMSG^BEHOXQ` returns an alert's long text through `ENTRY^XQALGUI` (`GETLONG`), then adds its forwarding comment from the ALERT file (#8992). The stock route is not switched to yet. | `XQAL GUI ALERTS` (`ENTRY^XQALGUI`, in its own option `XQAL GUI ALERTS`) for the text, and a DDR read of #8992 for the comment, unverified. |
| `BEHOXQ ALRPP` | `RpmsRpc::Notifications` | `ALRPP^BEHOXQ` runs the alert's IHS post-processing code (file 90460.021, node 3), which is how VueCentric clears an alert. That handler exists only in BEHOXQ. | None; `ORB DELETE ALERT` deletes without the handler, unverified. |
| `BEHOXQ FORWARD` | `RpmsRpc::Notifications` | `FORWARD^BEHOXQ` calls `FORWARD^XQALFWD`, the Kernel forward. | `ORB FORWARD ALERT` (`OR CPRS GUI CHART`), a candidate, unverified. |
| `BGOPROB DEL` | `RpmsRpc::Problem` | `ORQQPL DELETE` loses SNOMED CT, laterality and the IHS problem numbering. Decided (#527). | None; stays. |
| `BGOPROB SET` | `RpmsRpc::Problem` | `ORQQPL ADD SAVE` / `EDIT SAVE` lose the same. Decided (#527). | None; stays. |
| `BGOREF GETREA` | `RpmsRpc::ImmunizationRefusal` | Refusals; no stock route found. | None; primary care, planned for later. |
| `BGOREF SET` | `RpmsRpc::ImmunizationRefusal` | As above. | As above. |
| `BGOVCPT GET` | `RpmsRpc::Procedure` | The V CPT read VueCentric's procedure component uses. | DDR LISTER on V CPT (#9000010.18). |
| `BGOVEXAM SET` | `RpmsRpc::ExamComponent` | Exam entries; no stock route checked. | `BEHOENPC SAVE` also files exams (VueCentric-only); otherwise none. |
| `BGOVHF SET` | `RpmsRpc::HealthFactor` | Health factors; which store a BH screening belongs in is unconfirmed. | `AMHG SAVE SCREENING` for BH, probable. |
| `BGOVIMM GET` | `RpmsRpc::Immunization` | Immunization reads; no stock route. | None; primary care, planned for later. |
| `BGOVIMM GETVFC` | `RpmsRpc::Eligibility` | VFC eligibility; as above. | As above. |
| `BGOVIMM PROFILE` | `RpmsRpc::Immunization` | `PROFILE^BGOVIMM2` wraps `IMMPROF^BIRPC`. The BI package's own RPCs (`BI PATIENT PROFILE GET` and the rest) are registered in no broker option on the build. | None until BI's RPCs are in an option. |
| `BGOVIMM2 GETELIG` | `RpmsRpc::Eligibility` | As for `BGOVIMM GETVFC`. | As above. |
| `BGOVMSR GET` | `RpmsRpc::Measurement` | Measurements; GMV not checked. | `AMHG SAVE MEASUREMENTS` for BH; otherwise unverified. |
| `BGOVMSR LAST` | `RpmsRpc::Measurement` | As above. | As above. |
| `BGOVMSR SET` | `RpmsRpc::Measurement` | As above. | As above. |
| `BGOVPOV RECENT` | `RpmsRpc::Pov` | `RECENT^BGOVPOV` lists V POVs by patient or by visit, with SNOMED CT, asthma control and the lock flag. `ORWPCE PCE4NOTE` gives one visit's diagnoses only. | DDR LISTER on V POV (#9000010.07). |
| `BGOVPOV SET` | `RpmsRpc::Pov` | Visit diagnosis outside BH. | `AMHG SAVE POV` for BH; `BEHOENPC SAVE` (VueCentric-only) otherwise. |
| `BGU MAILMAN MESSAGE` | `RpmsRpc::Bgu` | `EN^BGUMAIL` sends a MailMan message to a mail group (`^XMD`). The other MailMan RPCs on the build (`PSB MAIL`, `SC MAILMAN`) belong to their packages' options. | None found. |
| `CIAVCXUS VIMINFO` | `RpmsRpc::Session` | Reads the signed-on DUZ on a CIA session. | `XUS GET USER INFO`, unverified (see docs/vuecentric-exit.md, open points). |

## Consequences

### Positive

- Every VueCentric-only RPC the gem sends is a written choice with a reason and a way out.
- The list cannot drift: a new one, or one that stops being VueCentric-only, fails a test until this table changes.

### Negative

- The list is computed against one build's inventory (the one `required_rpcs.json` names). A build whose options differ needs its inventory pinned before the test reflects it.
- On a session bound to another option, each of these calls costs a bind and a restore.
- The bind covers these RPCs only. A method that also sends an RPC the session's option lacks still needs that option bound: `Measurement.latest` reads `DDR GETS ENTRY DATA` beside `BGOVMSR LAST`, and `OR CPRS GUI CHART` does not carry it.

### Alternatives considered

- **Leave the list in docs/vuecentric-exit.md.** That document is analysis, with a count that has already drifted (37 there, 41 here). A list a test checks cannot drift.
- **Move every write to a stock route first.** For the problem list and the CPT, the stock routes lose data or do not work on the build (#527, #524).

## References

- docs/vuecentric-exit.md, for the needs, the stock candidates and the class of each.
- `test/rpms_rpc/vuecentric_only_rpcs_test.rb` (the list and each RPC's option) and `test/live/vuecentric_only_context_live_test.rb` (the bind, live).
- rpms-rpc#527, #524, #645, #661; rpms-ops#1042.
