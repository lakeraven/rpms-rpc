# Chart-read pilot status on bcer-9.0-20261119-f67498c-ydb (issue #224).
# Seed patient DFN 2, captured live signed on as PROV123.
# A field is proven only by a real value -- not empty, not a masked or pseudo
# placeholder (see RpmsRpc::WireCapture::Evidence). A boolean is proven only
# when both true and false were observed. ORWPT CWAD is judged on
# Patient.brief_header allergy_flag and ad_flag, and a flag is proven only
# when a captured letter maps it true (a false flag is a missing letter).
# ORWPS ACTIVE is judged on Medication.active_for_patient (order_id, type,
# name, status, stop_date, instructions, comments). BEHOPTCX PTINFO ssn stays
# unproven: FMTSSN masks it as XXX-XX-XXXX.
# Known limits of this grading: a Y/N flag (veteran, sex) is proven from a single
# observed value, not both (L6).
# One line per RPC: RPC | status | reason | unproven: <fields or none>

ORWPT ID INFO | partial | mapped ssn, sc_percent, ward_location, and room_bed are nil for outpatient DFN 2 (USER,TEST, sex M, veteran N, dob 1985-05-05) signed on as PROV123 | unproven: room_bed, sc_percent, ssn, ward_location
BEHOPTCX PTINFO | partial | mapped designated_team and primary_provider are nil for DFN 2 signed on as PROV123; mrn is 123456 ($$HRN for that sign-on division, blank on bcer-9.0-20261012-e7923a4-ydb); ssn maps to FMTSSN's constant mask XXX-XX-XXXX, populated on the wire but not evidence | unproven: designated_team, primary_provider, ssn
BEHOPTPC GETBDP | not-proven | live call for DFN 2 signed on as PROV123 returned no data rows (empty designated provider in the seed), so no mapped label, provider_name, provider_ien, title, or date_raw | unproven: date_raw, label, provider_ien, provider_name, title
ORWPT CWAD | not-proven | there is no live ORWPT CWAD capture on bcer-9.0-20261119-f67498c-ydb yet (routine-cited only; main moved brief_header's CWAD read from BEHOCACV CWAD to ORWPT CWAD), so persona PROV123 has not proven brief_header flags | unproven: ad_flag, allergy_flag
ORQQPL LIST | partial | both of DFN 2's rows (IEN 1 *TYPE 2 DIABETES MELLITUS, IEN 2 *ESSENTIAL HYPERTENSION) signed on as PROV123 are inactive-ICD (piece 13 "#"), so mapped icd_code and transcribed are nil and inactive_icd is true on every row (false was not mapped); piece 4 is $$ICDDX "Invalid Code (not found in the ICD-9-CM system)", which is not code-shaped and is never an icd_code; priority, service_connected, and special_exposures are blank | unproven: icd_code, inactive_icd, priority, service_connected, special_exposures, transcribed
ORQQAL LIST | partial | mapped severity is nil on DFN 2's penicillin allergy (IEN 1, signs HIVES) signed on as PROV123 | unproven: severity
ORWPS ACTIVE | partial | live call for DFN 2 signed on as PROV123 returns the seeded outpatient ASPIRIN prescription (1R;O, ACTIVE, stop date 2027-11-19) and a pending order for the same drug (2P;O, PENDING, no stop date), each with its quantity and Sig lines, so Medication.active_for_patient proved order_id, type, name, status, stop_date and instructions; neither carries a comment line (on bcer-9.0-20261012-e7923a4-ydb the seed had no prescription and the reply was empty) | unproven: comments
ORQQVI VITALS | partial | mapped qualifiers is nil on all four vitals (PU 82, BP 142/88, HT 70, WT 214) for DFN 2 signed on as PROV123 | unproven: qualifiers

# Registration pilot status on bcer-9.0-20261119-f67498c-ydb (issue #562, slice of #224).
# Register, find and possible-match through the AG package (AGGRPC). The VOA + DDR
# composition fallback was removed in #409 and has no code path to prove.
# AGG LOOKUP PATIENTS is graded on mapped :patient_lookup_agg values of its committed
# live capture (signed on as PROV123, possible-match form, seed patient DFN 2).
# A write is never proven by a capture: an AG write row stays not-proven until it is
# live-verified as PROV123 by test/live/pilot_registration_live_test.rb, which reads the
# filed HRN back from #9000001.41.
# Live failure behind green tests: as PROV123, AG answered success for every HRN source
# (derive, temporary, given) while #9000001.41 stayed empty. Patient.register now
# returns :hrn_file_failed with the DFN instead. PROV123 (NEW PERSON DUZ 200) has one
# DIVISION entry, INSTITUTION IEN 1, which does not exist on this build; SYS123's
# division is 7819 DEMO IHS CLINIC, and as SYS123 the HRN files and reads back.
# UNFIXTURED, not verified: a manual run on a disposable container that pointed PROV123's
# division at 7819 reported that HRN filing and free-text find then worked. No committed
# capture backs that run, so it is a lead for the openrpms seed issue, not evidence.
# Free-text find (Patient.lookup "USER,TEST") returned the header only as PROV123 and
# found DFN 2 as SYS123 in a manual run (UNFIXTURED); an HRN find (123456) is also
# UNFIXTURED. What IS fixtured is the possible-match capture (agg-lookup-patients.yml) as
# PROV123. COMM and MOMDN columns come only when ^AGFAC(DUZ(2),0) piece 11 is Y
# AND ALL=1 (AGGPTLKP.m:175, 207), so they are absent for PROV123's missing division.
# Known limit of the registration write path, pre-existing and not fixed by this
# slice (so a live capture here does not make registration retry-safe):
#  - rpms-rpc#609: Patient.lookup reads a header-only error reply (ERR^AGGPTLKP answers an
#    M error with the typed header and a $C(31) terminator, AGGPTLKP.m:165-171) as zero
#    candidates, so the duplicate-identity check passes and a retry during a lookup
#    fault can create a second chart for the same person.
# rpms-rpc#610 is fixed: a derived HRN (HRN := DFN) is put to HRN^AGGWVAL with the new
# DFN before it is filed, and one another patient holds at the facility is refused
# (:hrn_already_assigned), live-proven in test/live/registration_hrn_source_live_test.rb.

AGG LOOKUP PATIENTS | partial | live possible-match capture signed on as PROV123 returned DFN 2 (USER,TEST, HRN 123456-DIC, DOB MAY 5,1985, sens NO, inactive N); ssn, dod and alias are blank for that seed patient, and community and mothers_maiden_name are not sent without an ^AGFAC entry for PROV123's division; free-text name find returns no rows as PROV123 (seed-data gap) | unproven: alias, community, dod, mothers_maiden_name, ssn_raw
AGG ADD NEW PATIENT | not-proven | (limit: see rpms-rpc#609 above) creates the chart as PROV123, but a given HRN riding the create was not on #9000001.41 afterwards (PROV123's division is a missing INSTITUTION); register now fails closed with :hrn_file_failed; live-proven as SYS123 only | unproven: hrn
AGG UPDATE PATIENT | not-proven | the derive (HRN := DFN) update answered success as PROV123 while #9000001.41 stayed empty; register now fails closed with :hrn_file_failed; live-proven as SYS123 only | unproven: hrn
AGG GET TEMP PAT HRN | not-proven | returns the next T-number as PROV123, but the update filing it left #9000001.41 empty; register now fails closed with :hrn_file_failed; AGGPTHRN.m:15 sets ^AUPNPAT("D",THRN,DFN,DUZ(2)) before the update, so on that fail-closed path the T-number stays indexed to a chart whose #9000001.41 is empty (AUPNLK1I.m:17 resolves it in a FileMan lookup and HRN^AGGWVAL:103 sees it as assigned) and the :hrn_file_failed hash drops hrn, so the caller cannot tell which T-number was consumed; live-proven as SYS123 only | unproven: hrn

# Visit and encounter pilot status on bcer-9.0-20261119-f67498c-ydb (issue #563, slice of #224).
# Seed patient DFN 2, seed visit IEN 1 at hospital location 10 (DEMO PRIMARY CARE, 6 before openrpms#1252), captured live signed on as PROV123
# (rake wire:capture, host mode, PINNED=1). Grading is the chart-read grading above.
# BEHOENCX CHKVISIT returns one COMPONENT^TEXT row per check whatever the outcome (CV1 overwrites
# the status code, BEHOENCX.m:329-337), so Encounter.open used to report POV missing on visit 1,
# which has one: a mapping that failed live although its tests passed. Fixed in this slice.
# Write rows have no capture: wire:capture sends no write RPC, with one exception. BEHOENCX CHKVISIT
# is captured live although it can file a Kernel alert (NOEMC, BEHOXQPC.m:37-41 into SEND 64-74,
# ENTRY^XQALGUI) when a visit has a note but no E&M code. That is accepted: the capture runs only on a
# disposable pinned build (the alert would land in file #8992 there) and seed visit 1 has no note, so
# none is filed; any change to the seed visit must re-check it. Write rows are judged by
# test/live/encounter_visit_live_test.rb and test/live/behavioral_health_save_pcc_visit_live_test.rb.
# Seed gaps for openrpms (one issue, openrpms#1078): PROV123 fails $$ISPROV^BEHOUSCX, so the pilot
# clinician persona is not a provider (affects FETCH piece 4 and any provider-gated call); PROV123's
# division had no PCC MASTER CONTROL (#9001000) entry on that build, a gap closed by
# bcer-9.0-20261116-2a9b3fe-ydb (see FETCH CREATE=1 below, re-graded on that build, #798).
# A write row's status and unproven list are for the pilot persona PROV123; what SYS123 proved is
# stated in the reason but does not make the row pilot-ready.

BEHOENCX GETVISIT | partial | visit 1 for DFN 2 signed on as PROV123 returns location 10, 3260825.09, service category A and patient 2; mapped visit_id is blank (VISIT ID 15001 not set on the seed visit) and locked was observed only as 0, never 1 | unproven: locked, visit_id
BEHOENCX FETCH | partial | CREATE=0 read of visit 1 for DFN 2 signed on as PROV123 returns DEMO PRIMARY CARE, provider 200 PROVIDER,TEST (PROV123's own DUZ; it was 12 DEMO,DOCTOR on bcer-9.0-20261012-e7923a4-ydb) and visit 1; which rule supplies piece 4 is not pinned by a test (the visit's primary provider, or GETPRV2 under the XPAR BEHOENCX PROV ENC FETCH, BEHOENCX.m:36-40, which was not observed); room_bed is blank for the outpatient, visit_id is blank (^AUPNVSIT(1,150) not set), locked was observed only as 0, and error is set only when the visit does not resolve | unproven: error, locked, room_bed, visit_id
BEHOENCX CHKVISIT | pilot-ready | visit 1 signed on as PROV123 returns POV^Visit has POV and E&M^Visit has no note; pilot-ready grades the mapped component and message fields; Encounter.open now lists only E&M (not checked: no note), since POV is present, and of the four present/not-required texts it drops only Visit has POV was seen live (the other three are read from BEHOXQPC.m and fail closed if they differ); visit 1 has no note, so no alert is filed by the call | unproven: none
BEHOENCX FETCH CREATE=1 | partial | on bcer-9.0-20261116-2a9b3fe-ydb, signed on as PROV123, test/live/encounter_visit_live_test.rb passes (#798): CREATE=0 finds no visit on an unused date, CREATE=1 files one for DFN 2 at location 6 (visit 118 in a probe on that build, provider 200 PROVIDER,TEST), a second identical CREATE=1 returns the same IEN, CREATE=0 then finds it, and BEHOENCX GETVISIT reads back patient 2, location 6, service category A and the sent date; visit_id came back blank (VISIT ID 15001 not set) and locked only as 0, and the spec asserts neither. On bcer-9.0-20261012-e7923a4-ydb the same create replied "Error Creating Visit" as PROV123 (its division, institution 1, had no PCC MASTER CONTROL entry, so APCDALV refused with .03 TYPE OF VISIT MISSING); that seed gap is closed on the graded build | unproven: locked, visit_id
AMHG CREATE/EDIT VISIT | not-proven | signed on as PROV123 (and SYS123) EN^AMHBHRU refuses with 0~Activity Type Missing! because BehavioralHealth.save_visit cannot file #9002011 .06 activity type, so PCC VISIT LINK .16 stays blank and no PCC visit is linked (rpms-rpc API gap, not seed) | unproven: row

# Scheduling write pilot status on bcer-9.0-20261116-2a9b3fe-ydb (issues #565, #626, part of #224).
# Captured by `rake wire:capture_writes` (LIVE_DISPOSABLE=1, loopback broker), seed patient
# DFN 3 on the synthetic resource ZZ PILOT SCHED CAPTURE (hospital location 3). A write's
# reply is never proof by itself: each effect is proven only by a DDR GETS read-back of
# #9002018.4 or #2.98 (internal values) equal to what the API sent.
# pilot-ready needs every effect proven with the capture signed on as PSCH123,
# PROFILE,SCHED, the scheduling persona whose role this is (#452, #626). A capture signed on
# as another persona proves the mapping live but leaves every effect unproven for the pilot.
# The captures are from bcer-9.0-20261116-2a9b3fe-ydb, the latest published release (the
# maintainer's decision for #626, 2026-11-18), not the pin. On a fresh volume of it the
# setup persona (SYS123) creates the synthetic resource ZZ PILOT SCHED CAPTURE (no BSDX
# RESOURCE is seeded for it); the file room printer is already set on every BSD PARAMETERS
# entry, and PSCH123's sign-on division (7819) is a MEDICAL CENTER DIVISION (#40.8)
# institution, so the seed gaps that refused PROV123's booking on the old pin do not apply
# (the fixtures' setup.notes, setup.division and setup.medical_center_division_institutions).
# PROV123 is refused BSDXRPC on this build (least_privilege_live_test.rb).
# One line per RPC: RPC | status | reason | unproven: <effects or none>

BSDX ADD NEW APPOINTMENT | pilot-ready | signed on as PSCH123 (DUZ 208, division 7819), appointment 1 booked at 3261209.09 for DFN 3 on the synthetic resource; #9002018.4 (.01 start, .05 patient, .07 resource) and #2.98 (.01 clinic) read back what was sent: not the .02 end time | unproven: none
BSDX CHECKIN APPOINTMENT | pilot-ready | signed on as PSCH123 (DUZ 208), appointment 1 checked in at 3261118.18; #9002018.4 .03 and the clinic's #44.003 entry (patient 3, field 309, checked in by 208) read back that time, both empty just before the call; the call sends the 8 client formals the capture ran with (BSDX25.m:12 through BSDXOG); the build's tag takes three more ($G-guarded, BSDX25.m:67-69) that this API does not send, and an 11-actual call shape has not been dispatched live; check-in, cancel and no-show take only the appointment IEN and the API has no patient cross-check | unproven: none
BSDX CANCEL APPOINTMENT | pilot-ready | signed on as PSCH123 (DUZ 208), appointment 2 cancelled type PC with coded reason 5; the reply is an empty ERRORID row (no-data, not proof by itself), and #2.98 reads back status PC, reason 5 and user 208, #9002018.4 .12 a cancel time, none of them set just before the call | unproven: none
BSDX NOSHOW | pilot-ready | signed on as PSCH123 (DUZ 208), appointment 3 marked no-show; #9002018.4 .1 reads back 1 and #2.98 status N and user 208 on the patient record, neither set just before the call | unproven: none

# TIU note-write pilot status on bcer-9.0-20261119-f67498c-ydb (issue #564, slice of #224).
# One flow written by `WRITES=1 rake wire:capture` (host mode, loopback broker), signed on as
# PROV123. The flow first checks BEHOENCX GETVISIT on visit 4 and creates only when its patient
# piece is 4. That GETVISIT capture is not committed (rake wire:capture keeps only the write
# entries, lib/tasks/wire.rake). The visit-patient pair is in two committed fixtures instead:
# test/fixtures/wire_captures/orwpce-get-visit.yml (GETVISIT^ORWPCE2 for note 3, DFN 4, answers
# visit 4) and orwpce-pce4note.yml (note 3's encounter, VST^PT^4). The seed holds TIU documents 1-5,
# all on DFN 4: documents 1-4 on visit 4 and document 5 on visit 5 (DDR LISTER on #8925 fields .02
# and .03, read live on bcer-9.0-20261109-d3adcff-ydb; not a committed fixture). ProgressNote.create itself does not compare the visit's patient with DFN, and
# neither does MAKE^TIUSRVP (VSTRBLD, TIUSRVP.m:80-85); the gate is in the capture flow only.
# Then lock, update_text (a line over WRAP_WIDTH, #479), the TIU GET RECORD TEXT read-back, and
# unlock, on seed patient DFN 4, visit 4, title 248 PROGRESS NOTE. The note IEN is run-dependent:
# the build volume may be reused, so a create returns the next free IEN (this capture ran on a
# fresh volume, where the seed holds TIU documents 1-5, and created note 6 on DFN 4, visit 4).
# A write is proven only when the gem's public API reads its captured reply as success
# (RpmsRpc::WireCapture.write_evidence?). A refused write is never evidence.
# Failed live while its tests passed: the read-back check split rows on \r?\n, but this build
# separates TIU GET RECORD TEXT rows with a bare \r; fixed in this slice.
# Write-path limits: SETTEXT^TIUSRVPT (TIUSRVPT.m:7-38) has no author or authorization check
# server-side; a DUZ that differs from the author only files a VBC line count (TIUSRVPT.m:32-36).
# TIU LOCK RECORD is an M job lock, not ownership (TIUSRVP.m:211). So ProgressNote.update_text
# calls ProgressNote.authorize (TIU AUTHORIZATION, EDIT RECORD) first and sends TIU SET DOCUMENT
# TEXT only on its "1" (lakeraven/rpms-rpc#614). TIU SIGN RECORD is server-guarded:
# CANDO^TIULP (TIUSRVP2.m:49) runs before VALIDATE (TIUSRVP2.m:51).
# Evidence limits of the capture itself:
# - The esig gate (WireCapture.write_refusal) refuses a code found in the note text or the
#   withheld marker before the run; it cannot know the read-back header. A code equal to a
#   header word (for example UNSIGNED or PROVIDER) is caught in the captures instead: SIGN
#   does not fire, and every capture of the run is dropped, so the fixture set never mixes
#   note IENs (rpms-rpc#617). Choose a code that is not an English word, or the run records nothing.
# - The TIU GET RECORD TEXT reply carries no note IEN (no TIUDA). Its evidence is bound to the
#   note by the call's input and by the note text matching, not by anything in the reply.
# One line per RPC: RPC | status | reason | unproven: <fields or none>

TIU CREATE RECORD | pilot-ready | live capture signed on as PROV123 returned new note IEN 6 for DFN 4 visit 4 title 248; BEHOENCX GETVISIT signed on as PROV123 returned patient 4 for visit 4 before the create; ProgressNote.create reads it as success | unproven: none
TIU LOCK RECORD | pilot-ready | live capture signed on as PROV123 returned 0 (lock held) on note 6; ProgressNote.lock reads it as true | unproven: none
TIU SET DOCUMENT TEXT | pilot-ready | live capture signed on as PROV123 returned 6^1^1 on note 6 for the wrapped two-line note; update_text reads it as success; SETTEXT^TIUSRVPT has no author check, so update_text sends it only after TIU AUTHORIZATION (EDIT RECORD) answers 1, captured live for the author and refused for another user (#614) | unproven: none
TIU GET RECORD TEXT | pilot-ready | live read-back signed on as PROV123 of note 6 matches the note lines row for row after the header (only a wrap-boundary space or hard cut tolerated), each wrapped line within WRAP_WIDTH (80 bytes) | unproven: none
TIU UNLOCK RECORD | pilot-ready | live capture signed on as PROV123 returned 0 on note 6; ProgressNote.unlock reads it as true | unproven: none
TIU SIGN RECORD | pilot-ready | live capture signed on as PROV123 returned 0 on note 6 with PROVIDER,TEST's demo signature code (NEW PERSON 20.4, seeded by openrpms#1247; the code is withheld); ESignature.add reads it as success; test/live/progress_note_sign_live_test.rb reads #8925 back as COMPLETED, SIGNED BY 200, with a signature date/time, and a wrong code is refused with 89250005 leaving the note UNSIGNED (captured in test/fixtures/captured_replies/e-signature-clinician.yml, #720) | unproven: none
