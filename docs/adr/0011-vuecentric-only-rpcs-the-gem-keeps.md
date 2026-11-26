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

The list is computed, not kept by hand: an RPC is on it when `lib/rpms_rpc/required_rpcs.json` names it and the broker-option inventory of the openrpms release under test (`<tag>-contexts_19_05.txt`, fetched by `rake openrpms:fetch`, rpms-rpc#724) lists it in `CIAV VUECENTRIC` only.
On `bcer-9.0-20261124-60d39b6-ydb` that is 77 RPCs.

## Decision

1. The gem keeps the 77 RPCs below. Each row names the module that sends it, why no stock route is used yet, and the route that would replace it.
2. A VueCentric-only RPC is added to the gem only with a row here, in the same change. `test/rpms_rpc/vuecentric_only_rpcs_test.rb` fails when `required_rpcs.json` gains one this table does not list, and when the table lists one that is no longer VueCentric-only or no longer sent.
3. The problem-list writes and the psych CPT are decided, not pending: problem writes stay on `BGOPROB SET` / `BGOPROB DEL` (#527), and the CPT is filed through `BEHOENPC SAVE` (#524). Both are live-proven.
4. Leaving one of these for a stock route takes its own change: the stock route proven live, the RPC gone from `required_rpcs.json`, and its row deleted.
5. Each of these RPCs binds its own option. Its mapping declares it (`m.context VUECENTRIC` in `lib/rpms_rpc/mappings/ihs.rb`), and DataMapper sends the call under that option and restores the caller's (`ContextScope.scoped`). An API that sends the RPC itself, to read the raw reply, does so inside the mapping's `in_context`, so the RPC answers whichever option the session has bound. On a CIA session, already bound to `CIAV VUECENTRIC` by sign-on, that costs nothing. The test fails when a VueCentric-only RPC's mapping declares no option, and `test/live/vuecentric_only_context_live_test.rb` proves the bind on the pinned build.

| RPC | Used by | Why no stock route yet | Replacement path |
|---|---|---|---|
| `BEHOART SIGNLIST` | `RpmsRpc::Allergy` | The allergy entries the signed-on user must sign or may verify (`$$CANSIGN` / `$$CANVERIF^BEHOART`); no stock sign-list RPC checked. | DDR LISTER on #120.8 plus the GMRA verify rules, unverified. |
| `BEHOCACV LIST` | `RpmsRpc::Patient` | The patient's postings behind the CWAD letters: TIU postings (`ENCOVER^TIUPP3`) and active record flags in one list. Not compared with `ORQQPP LIST`. | `ORQQPP LIST` for the TIU postings plus `ORPRF HASFLG` for the flags, unverified. |
| `BEHOCCD GETREF` | `RpmsRpc::Phr` | PHR and C-CDA reads; no stock RPC outside `CIAV VUECENTRIC` serves them. | None planned for December; the C-CDA is built in Rails. |
| `BEHOCCD PHR` | `RpmsRpc::Phr` | As above. | As above. |
| `BEHOCIR GETNUM` | `RpmsRpc::Phr` | As above. | As above. |
| `BEHOCIR1 GETCCDS` | `RpmsRpc::Phr` | As above. | As above. |
| `BEHOENCX CHKVISIT` | `RpmsRpc::Encounter` | The visit-context calls VueCentric makes; the stock routes that create a visit are package writes, not yet verified on a running image. | `BSDX CHECKIN APPOINTMENT` (creates the visit when the clinic's flag is set) or `AMHG SAVE VISIT` for BH. |
| `BEHOENCX FETCH` | `RpmsRpc::Encounter`, `RpmsRpc::Scheduling` | As above. | As above. |
| `BEHOENCX GETPRV` | `RpmsRpc::Encounter` | A visit's providers by visit string; the visit-context calls above. | DDR LISTER on V PROVIDER (#9000010.06), unverified. |
| `BEHOENCX GETVISIT` | `RpmsRpc::ClinicalReview`, `RpmsRpc::Encounter`, `RpmsRpc::Measurement` | As above. | As above. |
| `BEHOENCX VISITLST` | `RpmsRpc::Encounter` | `VISITLST^BEHOENCX` lists the patient's visits with the IHS lock flag (`ISLOCKED^BEHOENCX`), the primary provider and a standalone flag, then appointments pending check-in (`SDA^VADPT`). `ORWCV VST` and `ORQQVS VISITS/APPTS` (`OR CPRS GUI CHART`) list visits and appointments without those fields. Not compared live. | `ORWCV VST` plus a DDR read of VISIT for the lock and provider, unverified. |
| `BEHOENPC SAVE` | `RpmsRpc::Encounter`, `RpmsRpc::Procedure` | Files the visit and its V files in one call. `ORWPCE SAVE` is registered to `SAVE^CIAVCXPC`, which the build does not carry (openrpms#1042). Decided for the psych CPT (#524). `Encounter.save` files a whole encounter through it (#921); each V POV is linked to the problem list by `PROBLST^BEHOENP2`. | None outside `CIAV VUECENTRIC`. |
| `BEHOLRCV LIST` | `RpmsRpc::Lab` | The patient's lab orders over the site's cover-sheet range (`BEHOLRCV DATE RANGE`), as VueCentric's lab cover sheet lists them; it calls stock `LIST^ORQOR1`. | `ORQOR LIST` (`LIST^ORQOR1`, `OR CPRS GUI CHART`) with the range passed by the caller, unverified. |
| `BEHOPGAP GETGOAL` | `RpmsRpc::PatientGoal` | A patient's goals (PATIENT GOALS, #9000093) with types and reviews, as VueCentric's Patient Goals component lists them; no stock route checked. | DDR LISTER on #9000093, unverified. |
| `BEHOPTPC GETBDP` | `RpmsRpc::Patient` | Designated provider. `ORWPT1 PRCARE` reads PCMM, which IHS sites do not fill. | DDR read of IHS PATIENT (#9000001) .14. |
| `BEHOPTPL DOBLKP` | `RpmsRpc::PatientSelection` | VueCentric's patient lookups; behaviour not compared with a stock lookup. | `AGG LOOKUP PATIENTS` (`AGGRPC`), a candidate. |
| `BEHOPTPL HRNLKP` | `RpmsRpc::PatientSelection` | As above. | As above. |
| `BEHOPTPL LISTALL` | `RpmsRpc::PatientSelection` | As above. | As above. |
| `BEHOPTPL LOOKUP` | `RpmsRpc::PatientSelection` | As above. | As above. |
| `BEHORXFN GETRXS` | `RpmsRpc::Medication` | The medication profile with the IHS fields (NDC, RxNorm, indication, prescription number, chronic flag) that `ORWPS ACTIVE` does not carry. | `ORWPS ACTIVE` plus DDR reads of PRESCRIPTION (#52) for the IHS fields, unverified. |
| `BEHOSICX SITEINFO` | `RpmsRpc::Site` | A stock route exists and is not switched to yet. | `XUS GET USER INFO` line 3 and `XUS DIVISION GET`. |
| `BEHOVM GRID` | `RpmsRpc::Vital` | Vitals; the GMV vitals RPCs are not checked. | `AMHG SAVE MEASUREMENTS` for BH; GMV for the rest, unverified. |
| `BEHOVM LIST` | `RpmsRpc::Vital` | As above. | As above. |
| `BEHOVM SAVE` | `RpmsRpc::Vital` | As above. | As above. |
| `BEHOVM TEMPLATE` | `RpmsRpc::Vital` | As above. | As above. |
| `BEHOVM VALIDATE` | `RpmsRpc::Vital` | As above. | As above. |
| `BEHOVM2 VUNITS` | `RpmsRpc::Measurement` | As above. | As above. |
| `BEHOXQ ALRLIST` | `RpmsRpc::Notifications` | `ALRLIST^BEHOXQ` reads the user's alerts (`^XTV(8992)`) and runs each alert's IHS handler (BEHOXQ file 90460.021) for its priority, type and patient. `ORWORB FASTUSER` (`OR CPRS GUI CHART`) lists the alerts without those handler fields. | `ORWORB FASTUSER`, if the handler fields can be dropped or rebuilt. |
| `BEHOXQ ALRMSG` | `RpmsRpc::Notifications` | `ALRMSG^BEHOXQ` returns an alert's long text through `ENTRY^XQALGUI` (`GETLONG`), then adds its forwarding comment from the ALERT file (#8992). The stock route is not switched to yet. | `XQAL GUI ALERTS` (`ENTRY^XQALGUI`, in its own option `XQAL GUI ALERTS`) for the text, and a DDR read of #8992 for the comment, unverified. |
| `BEHOXQ ALRPP` | `RpmsRpc::Notifications` | `ALRPP^BEHOXQ` runs the alert's IHS post-processing code (file 90460.021, node 3), which is how VueCentric clears an alert. That handler exists only in BEHOXQ. | None; `ORB DELETE ALERT` deletes without the handler, unverified. |
| `BEHOXQ FORWARD` | `RpmsRpc::Notifications` | `FORWARD^BEHOXQ` calls `FORWARD^XQALFWD`, the Kernel forward. | `ORB FORWARD ALERT` (`OR CPRS GUI CHART`), a candidate, unverified. |
| `BGOCC GET` | `RpmsRpc::ChiefComplaint` | The chief complaint as VueCentric's Triage tab files it, in V NARRATIVE TEXT (#9000010.34) of type CHIEF COMPLAINT; no stock route checked. | DDR LISTER on #9000010.34, unverified. |
| `BGOCC SET` | `RpmsRpc::ChiefComplaint` | As above. | DDR FILER on #9000010.34, unverified. |
| `BGOPROB DEL` | `RpmsRpc::Problem` | `ORQQPL DELETE` loses SNOMED CT, laterality and the IHS problem numbering. Decided (#527). | None; stays. |
| `BGOPROB GET` | `RpmsRpc::Problem` | The integrated problem list as VueCentric reads it: SNOMED CT, the facility-scoped number, IHS status, laterality, qualifiers and notes. `ORQQPL LIST` answers the stock row without them. | DDR LISTER on PROBLEM (#9000011), unverified. |
| `BGOPROB SET` | `RpmsRpc::Problem` | `ORQQPL ADD SAVE` / `EDIT SAVE` lose the same. Decided (#527). | None; stays. |
| `BGOPROB1 EDPROB` | `RpmsRpc::Problem` | The active problems that carry a SNOMED CT concept, as VueCentric offers them for education and care plans. | As for `BGOPROB GET`. |
| `BGOPROB1 GETONE` | `RpmsRpc::Problem` | One integrated-list problem, any status. | As for `BGOPROB GET`. |
| `BGOPROB2 DUPCHK` | `RpmsRpc::Problem` | The check VueCentric runs before it adds a concept: the patient's problems that hold it or an equivalent lateralized concept (`EQUIV^BSTSAPI`), else the concept as a new entry with the description and ICD codes BSTS gives it. No stock route checks SNOMED CT or laterality. | DDR LISTER on PROBLEM (#9000011) by the APCT and ASLT cross-references, without the BSTS equivalents, unverified. |
| `BGOREF GETREA` | `RpmsRpc::ImmunizationRefusal` | Refusals; no stock route found. | None; primary care, planned for later. |
| `BGOREF SET` | `RpmsRpc::ImmunizationRefusal` | As above. | As above. |
| `BGOUTL CHKSEC` | `RpmsRpc::Authentication` | Key flags and per-user parameter settings with the granting user class, in one call; how the BGO components decide editing (`BGO DISABLE ... EDITING`). Keys alone have the stock `ORWU NPHASKEY` (`held_keys`). | `ORWU NPHASKEY` for keys; for the parameter and its class grant, none found. |
| `BGOVCPT GET` | `RpmsRpc::Encounter`, `RpmsRpc::Procedure` | The V CPT read VueCentric's procedure component uses. | DDR LISTER on V CPT (#9000010.18). |
| `BGOVEXAM GET` | `RpmsRpc::ExamComponent` | The exams VueCentric lists for a patient (V EXAM), with the lock flag; no stock route checked. | DDR LISTER on V EXAM (#9000010.13), unverified. |
| `BGOVEXAM SET` | `RpmsRpc::ExamComponent` | Exam entries; no stock route checked. | `BEHOENPC SAVE` also files exams (VueCentric-only); otherwise none. |
| `BGOVHF GET` | `RpmsRpc::Encounter`, `RpmsRpc::HealthFactor` | The health factors VueCentric lists for a patient (V HEALTH FACTORS), with category and lock flag. | DDR LISTER on V HEALTH FACTORS (#9000010.23), unverified. |
| `BGOVHF SET` | `RpmsRpc::HealthFactor` | Health factors; which store a BH screening belongs in is unconfirmed. | `AMHG SAVE SCREENING` for BH, probable. |
| `BGOVIMM GET` | `RpmsRpc::Immunization` | Immunization reads; no stock route. | None; primary care, planned for later. |
| `BGOVIMM GETCASE` | `RpmsRpc::Immunization` | The patient's immunization registry entry (`GETCASE^BGOVIMM2`, GETS^DIQ of #9002084), or the package's not-registered answer. | DDR GETS ENTRY DATA on IMMUNIZATION PATIENT (#9002084), unverified. |
| `BGOVIMM GETCONT` | `RpmsRpc::Immunization` | The active contraindication reasons the immunization component offers (`GETCONT^BGOVIMM2`, #9002084.81); no stock route outside `CIAV VUECENTRIC` lists them. | DDR LISTER on #9002084.81 with the active screen, unverified. |
| `BGOVIMM GETVFC` | `RpmsRpc::Eligibility` | VFC eligibility; as above. | As above. |
| `BGOVIMM PROFILE` | `RpmsRpc::Immunization` | `PROFILE^BGOVIMM2` wraps `IMMPROF^BIRPC`. The BI package's own RPCs (`BI PATIENT PROFILE GET` and the rest) are registered in no broker option on the build. | None until BI's RPCs are in an option. |
| `BGOVIMM2 GETELIG` | `RpmsRpc::Eligibility` | As for `BGOVIMM GETVFC`. | As above. |
| `BGOVIMM5 DTERUN` | `RpmsRpc::Immunization` | The date the state forecaster last answered for a patient (`DTERUN^BGOVIMM5`, `^BYIMRT("RSP")`). | None planned for December: no stack runs the state forecaster. |
| `BGOVIMM5 FOREON` | `RpmsRpc::Immunization` | Whether the state forecaster is on (`FOREON^BGOVIMM5`, the BGO IMM REGISTRY ON parameter); the immunization component asks before it offers a state forecast. | `XPAR GET ALL` style reads of BGO IMM REGISTRY ON, unverified. |
| `BGOVIMM6 DUPALLOW` | `RpmsRpc::Immunization` | Whether a vaccine may be given twice on one day (`DUPALLOW^BGOVIMM6`, #9002084.97), the check the component makes before it files a second dose. | DDR GETS ENTRY DATA on #9002084.97, unverified. |
| `BGOVMSR GET` | `RpmsRpc::Measurement` | Measurements; GMV not checked. | `AMHG SAVE MEASUREMENTS` for BH; otherwise unverified. |
| `BGOVMSR LAST` | `RpmsRpc::Measurement` | As above. | As above. |
| `BGOVMSR SET` | `RpmsRpc::Measurement` | As above. | As above. |
| `BGOVPED GET` | `RpmsRpc::PatientEducation` | Patient education entries (V PATIENT ED) with the topic name VueCentric shows; no stock route checked. | DDR LISTER on V PATIENT ED (#9000010.16), unverified. |
| `BGOVPED2 GETPVED` | `RpmsRpc::PatientEducation` | A visit's problem-linked education (V PATIENT ED field 1103), as the problem-list education pane lists it; no stock route checked. | DDR LISTER on V PATIENT ED (#9000010.16) by visit, unverified. |
| `BGOVPOV DEL` | `RpmsRpc::Pov` | Removes a visit diagnosis and takes the visit off its problem's visit list (#9000011.14), so the problem no longer reads as used. | `BEHOENPC SAVE` (VueCentric-only) or DDR FILER on V POV (#9000010.07), which leaves the problem's visit list, unverified. |
| `BGOVPOV GET` | `RpmsRpc::Encounter`, `RpmsRpc::Pov` | One visit's diagnoses with episodicity, modifiers, injury, primary/secondary and qualifiers. `ORWPCE PCE4NOTE` gives the visit's diagnoses without those. | DDR LISTER on V POV (#9000010.07). |
| `BGOVPOV RECENT` | `RpmsRpc::Pov` | `RECENT^BGOVPOV` lists V POVs by patient or by visit, with SNOMED CT, asthma control and the lock flag. `ORWPCE PCE4NOTE` gives one visit's diagnoses only. | DDR LISTER on V POV (#9000010.07). |
| `BGOVPOV SET` | `RpmsRpc::Pov` | Visit diagnosis outside BH. | `AMHG SAVE POV` for BH; `BEHOENPC SAVE` (VueCentric-only) otherwise. |
| `BGOVTM GET` | `RpmsRpc::Encounter` | A provider's activity and travel time on a visit (V ACTIVITY TIME); no stock route checked. | DDR LISTER on V ACTIVITY TIME (#9000010.19) by visit, unverified. |
| `BGOVUPD GET` | `RpmsRpc::ClinicalReview` | That a list was reviewed or updated on a visit, as VueCentric files it in V UPDATED/REVIEWED (#9000010.54); no stock route checked. | DDR LISTER on #9000010.54, unverified. |
| `BGOVUPD SET` | `RpmsRpc::ClinicalReview` | As above. | DDR FILER on #9000010.54, unverified. |
| `BGU MAILMAN MESSAGE` | `RpmsRpc::Bgu` | `EN^BGUMAIL` sends a MailMan message to a mail group (`^XMD`). The other MailMan RPCs on the build (`PSB MAIL`, `SC MAILMAN`) belong to their packages' options. | None found. |
| `CIAVCXUS VIMINFO` | `RpmsRpc::Session` | Reads the signed-on DUZ on a CIA session. | `XUS GET USER INFO`, unverified (see docs/vuecentric-exit.md, open points). |
| `DG CHK PAT MEANS TEST REQUIRED` | `RpmsRpc::DgPatientSelect` | Whether registration must ask for a VA means test (`GUIMT^DPTLK6`), as the patient-selection flow checks; IHS sites keep no means test, and no stock route outside `CIAV VUECENTRIC` answers it. | None needed for IHS: the answer is 0 at an IHS site; drop it when the web tier stops asking. |
| `DGWPT CLINRNG` | `RpmsRpc::DgPatientSelect` | The date ranges a clinic patient list offers (`CLINRNG^DGWPT`), as VueCentric's patient-selection dialog shows them. Fixed text, no stock RPC outside `CIAV VUECENTRIC`. | The web tier's own list of ranges. |
| `DGWPT DIEDON` | `RpmsRpc::DgPatientSelect` | Whether the selected patient has died (`DIEDON^DGWPT`, `^DPT(DFN,.35)`), as patient selection warns. | DDR GETS ENTRY DATA on PATIENT (#2) .351, unverified. |
| `DGWPT SELCHK` | `RpmsRpc::DgPatientSelect` | Whether the record is sensitive or the user's own (`$$EN1^DGQPT2`), the check patient selection makes before it opens a record. | `DG SENSITIVE RECORD ACCESS` (`OR CPRS GUI CHART`), already wrapped by `RpmsRpc::DgSensitive`, which also logs the access. |
| `DGWPT SELECT` | `RpmsRpc::DgPatientSelect` | Selects the patient for the session and answers the banner pieces (`SELECT^DGWPT`), recording the user's last-selected patient. | `ORWPT SELECT` (`OR CPRS GUI CHART`), already wrapped by `RpmsRpc::Patient`, unverified as a drop-in. |
| `DGWPT TOP` | `RpmsRpc::DgPatientSelect` | The user's last-selected patient (`TOP^DGWPT`, `^DISV`), which patient selection offers first. | `ORWPT TOP` (`OR CPRS GUI CHART`), unverified. |
| `DGWPT1 PRCARE` | `RpmsRpc::DgPatientSelect` | The patient's primary care team, provider and attending (`PRCARE^DGWPT1`). It reads PCMM, which IHS sites do not fill. | DDR read of IHS PATIENT (#9000001) .14, the designated provider, as `BEHOPTPC GETBDP` gives it. |

## Consequences

### Positive

- Every VueCentric-only RPC the gem sends is a written choice with a reason and a way out.
- The list cannot drift: a new one, or one that stops being VueCentric-only, fails a test until this table changes.

### Negative

- The list is computed against the inventory of the openrpms release under test. A release whose options differ changes the list, and the test fails until this table follows.
- On a session bound to another option, each of these calls costs a bind and a restore.
- The bind covers these RPCs only. A method that also sends an RPC the session's option lacks still needs that option bound: `Measurement.latest` reads `DDR GETS ENTRY DATA` beside `BGOVMSR LAST`, and `Patient.brief_header` reads `BEHOPTCX PTINFO` (in `CIAV VUECENTRIC` and `VEN RPC`) beside `BEHOPTPC GETBDP`; `OR CPRS GUI CHART` carries neither. `PatientSelection.find` reads `BEHOPTCX PTINFO` for each patient its lookup lists, so it holds the `CIAV VUECENTRIC` bind for the whole search.

### Alternatives considered

- **Leave the list in docs/vuecentric-exit.md.** That document is analysis, with a count that has already drifted (37 there, 41 here). A list a test checks cannot drift.
- **Move every write to a stock route first.** For the problem list and the CPT, the stock routes lose data or do not work on the build (#527, #524).

## References

- docs/vuecentric-exit.md, for the needs, the stock candidates and the class of each.
- `test/rpms_rpc/vuecentric_only_rpcs_test.rb` (the list and each RPC's option) and `test/live/vuecentric_only_context_live_test.rb` (the bind, live).
- rpms-rpc#527, #524, #645, #661; openrpms#1042.
