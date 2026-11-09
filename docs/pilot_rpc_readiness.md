# Chart-read pilot status on bcer-9.0-20261012-e7923a4-ydb (issue #224).
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
BEHOPTCX PTINFO | partial | mapped mrn, designated_team, and primary_provider are nil for DFN 2 signed on as PROV123 (blank $$HRN for that sign-on division); ssn maps to FMTSSN's constant mask XXX-XX-XXXX, populated on the wire but not evidence | unproven: designated_team, mrn, primary_provider, ssn
BEHOPTPC GETBDP | not-proven | live call for DFN 2 signed on as PROV123 returned no data rows (empty designated provider in the seed), so no mapped label, provider_name, provider_ien, title, or date_raw | unproven: date_raw, label, provider_ien, provider_name, title
ORWPT CWAD | not-proven | there is no live ORWPT CWAD capture on bcer-9.0-20261012-e7923a4-ydb yet (routine-cited only; main moved brief_header's CWAD read from BEHOCACV CWAD to ORWPT CWAD), so persona PROV123 has not proven brief_header flags | unproven: ad_flag, allergy_flag
ORQQPL LIST | partial | both of DFN 2's rows (IEN 1 *TYPE 2 DIABETES MELLITUS, IEN 2 *ESSENTIAL HYPERTENSION) signed on as PROV123 are inactive-ICD (piece 13 "#"), so mapped icd_code and transcribed are nil and inactive_icd is true on every row (false was not mapped); piece 4 is $$ICDDX "Invalid Code (not found in the ICD-9-CM system)", which is not code-shaped and is never an icd_code; priority, service_connected, and special_exposures are blank | unproven: icd_code, inactive_icd, priority, service_connected, special_exposures, transcribed
ORQQAL LIST | partial | mapped severity is nil on DFN 2's penicillin allergy (IEN 1, signs HIVES) signed on as PROV123 | unproven: severity
ORWPS ACTIVE | not-proven | live call for DFN 2 signed on as PROV123 returned no data rows (no active medications in the seed), so Medication.active_for_patient proved none of order_id, type, name, status, stop_date, instructions, or comments | unproven: comments, instructions, name, order_id, status, stop_date, type
ORQQVI VITALS | partial | mapped qualifiers is nil on all four vitals (PU 82, BP 142/88, HT 70, WT 214) for DFN 2 signed on as PROV123 | unproven: qualifiers

# Registration pilot status on bcer-9.0-20261012-e7923a4-ydb (issue #562, slice of #224).
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
# capture backs that run, so it is a lead for the rpms-ops seed issue, not evidence.
# Free-text find (Patient.lookup "USER,TEST") returned the header only as PROV123 and
# found DFN 2 as SYS123 in a manual run (UNFIXTURED); an HRN find (123456) is also
# UNFIXTURED. What IS fixtured is the possible-match capture (agg-lookup-patients.yml) as
# PROV123. COMM and MOMDN columns come only when ^AGFAC(DUZ(2),0) piece 11 is Y
# AND ALL=1 (AGGPTLKP.m:175, 207), so they are absent for PROV123's missing division.
# Known limits of the registration write path, both pre-existing and not fixed by this
# slice (so a live capture here does not make registration retry-safe or HRN-unique):
#  - rpms-rpc#609: Patient.lookup reads a header-only error reply (ERR^AGGPTLKP answers an
#    M error with the typed header and a $C(31) terminator, AGGPTLKP.m:165-171) as zero
#    candidates, so the duplicate-identity check passes and a retry during a lookup
#    fault can create a second chart for the same person.
#  - rpms-rpc#610: with no HRN given, the derived HRN (HRN := DFN) is added after the
#    create and AG files it with .02/// (AGGPTUPD.m:104, AGGPTADD.m:112), which bypasses
#    the field input transform, so HRN^AGGWVAL's already-assigned check (AGGWVAL.m:101-110)
#    never runs. A new DFN equal to a legacy HRN at the facility files a second patient
#    under that HRN and the read-back reports success. The given-HRN mode does run
#    HRN^AGGWVAL.

AGG LOOKUP PATIENTS | partial | live possible-match capture signed on as PROV123 returned DFN 2 (USER,TEST, HRN 123456-DIC, DOB MAY 5,1985, sens NO, inactive N); ssn, dod and alias are blank for that seed patient, and community and mothers_maiden_name are not sent without an ^AGFAC entry for PROV123's division; free-text name find returns no rows as PROV123 (seed-data gap) | unproven: alias, community, dod, mothers_maiden_name, ssn_raw
AGG ADD NEW PATIENT | not-proven | (limits: see rpms-rpc#609 and #610 above) creates the chart as PROV123, but a given HRN riding the create was not on #9000001.41 afterwards (PROV123's division is a missing INSTITUTION); register now fails closed with :hrn_file_failed; live-proven as SYS123 only | unproven: hrn
AGG UPDATE PATIENT | not-proven | the derive (HRN := DFN) update answered success as PROV123 while #9000001.41 stayed empty; register now fails closed with :hrn_file_failed; live-proven as SYS123 only | unproven: hrn
AGG GET TEMP PAT HRN | not-proven | returns the next T-number as PROV123, but the update filing it left #9000001.41 empty; register now fails closed with :hrn_file_failed; AGGPTHRN.m:15 sets ^AUPNPAT("D",THRN,DFN,DUZ(2)) before the update, so on that fail-closed path the T-number stays indexed to a chart whose #9000001.41 is empty (AUPNLK1I.m:17 resolves it in a FileMan lookup and HRN^AGGWVAL:103 sees it as assigned) and the :hrn_file_failed hash drops hrn, so the caller cannot tell which T-number was consumed; live-proven as SYS123 only | unproven: hrn

# Visit and encounter pilot status on bcer-9.0-20261012-e7923a4-ydb (issue #563, slice of #224).
# Seed patient DFN 2, seed visit IEN 1 at hospital location 6, captured live signed on as PROV123
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
# Seed gaps for rpms-ops (one issue, rpms-ops#1078): PROV123 fails $$ISPROV^BEHOUSCX, so the pilot
# clinician persona is not a provider (affects FETCH piece 4 and any provider-gated call); PROV123's
# division has no PCC MASTER CONTROL (#9001000) entry (see FETCH CREATE=1 below).
# A write row's status and unproven list are for the pilot persona PROV123; what SYS123 proved is
# stated in the reason but does not make the row pilot-ready.

BEHOENCX GETVISIT | partial | visit 1 for DFN 2 signed on as PROV123 returns location 6, 3260825.09, service category A and patient 2; mapped visit_id is blank (VISIT ID 15001 not set on the seed visit) and locked was observed only as 0, never 1 | unproven: locked, visit_id
BEHOENCX FETCH | partial | CREATE=0 read of visit 1 for DFN 2 signed on as PROV123 returns DEMO PRIMARY CARE, provider 12 DEMO,DOCTOR and visit 1; piece 4 is INFERRED to be the visit's primary provider, not pinned by a test: it is 12, which differs from PROV123's DUZ, and PROV123 fails $$ISPROV^BEHOUSCX (so GETPRV2 under BEHOENCX PROV ENC FETCH, BEHOENCX.m:36-40, would supply it, but that presumes the XPAR BEHOENCX PROV ENC FETCH is set, which was not observed), while for a provider persona it is the signed-on user; room_bed is blank for the outpatient, visit_id is blank (^AUPNVSIT(1,150) not set), locked was observed only as 0, and error is set only when the visit does not resolve | unproven: error, locked, room_bed, visit_id
BEHOENCX CHKVISIT | pilot-ready | visit 1 signed on as PROV123 returns POV^Visit has POV and E&M^Visit has no note; pilot-ready grades the mapped component and message fields; Encounter.open now lists only E&M (not checked: no note), since POV is present, and of the four present/not-required texts it drops only Visit has POV was seen live (the other three are read from BEHOXQPC.m and fail closed if they differ); visit 1 has no note, so no alert is filed by the call | unproven: none
BEHOENCX FETCH CREATE=1 | not-proven | signed on as PROV123 the create replies "Error Creating Visit" (live spec); diagnosed in the container, not pinned by a test: PROV123's NEW PERSON division is institution 1, which has no PCC MASTER CONTROL (#9001000) entry, so FNDVIS sends a blank VISIT TYPE and APCDALV refuses with .03 TYPE OF VISIT MISSING (seed gap, rpms-ops); no V VISIT is written. Signed on as SYS123 (division 7819) the same call created a visit, a second CREATE=1 returned the same IEN, and CREATE=0 found it, but that is not the pilot persona | unproven: locked, visit_id, visit_ien
AMHG CREATE/EDIT VISIT | not-proven | signed on as PROV123 (and SYS123) EN^AMHBHRU refuses with 0~Activity Type Missing! because BehavioralHealth.save_visit cannot file #9002011 .06 activity type, so PCC VISIT LINK .16 stays blank and no PCC visit is linked (rpms-rpc API gap, not seed) | unproven: row

# Scheduling write pilot status on bcer-9.0-20261012-e7923a4-ydb (issue #565, part of #224).
# Captured by `rake wire:capture_writes` (LIVE_DISPOSABLE=1, loopback broker), seed patient
# DFN 3 on the synthetic resource ZZ PILOT SCHED CAPTURE (hospital location 3). A write's
# reply is never proof by itself: each effect is proven only by a DDR GETS read-back of
# #9002018.4 or #2.98 (internal values) equal to what the API sent.
# pilot-ready needs every effect proven with the capture signed on as PROV123, the pilot's
# least-privilege persona. A capture signed on as another persona proves the mapping live
# but leaves every effect unproven for the pilot.
# Seed gaps (rpms-ops seed issues to file) on a fresh volume of the pinned build:
# (1) no BSDX RESOURCE (#9002018.1) entry, so booking answers "Invalid Resource ID"
# (BSDX07.m:55), and no BSDX RESOURCE USER (#9002018.15) entries (DDR LISTER, observed
# while preparing the capture; not recorded in the fixtures); (2) BSD PARAMETERS
# (#9009020.2) entries have no FILE ROOM PRINTER (.05) (the capture driver sets the null device on every entry missing one), so booking answers "No file room
# printer is defined for the chart request." (BSDX07.m:64); (3) PROV123's sign-on division
# is INSTITUTION 1, and no MEDICAL CENTER DIVISION (#40.8) points to it (the fixtures'
# setup.division and setup.medical_center_division_institutions), so $$DIV^BSDU is 0 for
# PROV123 and booking answers the same printer refusal even with (2) fixed -- the ADD
# fixture's persona_probe is that refusal. On the disposable rung the capture creates the
# synthetic resource and sets the ZZNULL device as the printer (its setup.notes say so); it
# adds no RESOURCE USER entry and changes no division.
# One line per RPC: RPC | status | reason | unproven: <effects or none>

BSDX ADD NEW APPOINTMENT | not-proven | proven live signed on as SYS123 (division 7819; appointment 1 at 3261126.09 for DFN 3, the effects read back on #9002018.4 and #2.98: not the .02 end time), but PROV123's booking is refused with "BSDX07 Error: No file room printer is defined for the chart request." -- seed gap: PROV123's division, INSTITUTION 1, has no #40.8 MEDICAL CENTER DIVISION, so $$DIV^BSDU is 0 | unproven: appointment_id, dpt_appt_clinic, patient, resource, start
BSDX CHECKIN APPOINTMENT | pilot-ready | signed on as PROV123 (DUZ 200), appointment 1 checked in at 3261105.0805; #9002018.4 .03 and the clinic's #44.003 entry (patient 3, field 309) read back that time, both empty just before the call; the call sends the 8 client formals the capture ran with (BSDX25.m:12 through BSDXOG); the pinned build's tag takes three more ($G-guarded, BSDX25.m:67-69) that this API does not send, and an 11-actual call shape has not been dispatched live; check-in, cancel and no-show take only the appointment IEN and the API has no patient cross-check | unproven: none
BSDX CANCEL APPOINTMENT | pilot-ready | signed on as PROV123 (DUZ 200), appointment 2 cancelled type PC with coded reason 5; the reply is an empty ERRORID row (no-data, not proof by itself), and #2.98 reads back status PC, reason 5 and user 200, #9002018.4 .12 a cancel time, none of them set just before the call | unproven: none
BSDX NOSHOW | pilot-ready | signed on as PROV123 (DUZ 200), appointment 3 marked no-show; #9002018.4 .1 reads back 1 and #2.98 status N and user 200 on the patient record, neither set just before the call | unproven: none

# TIU note-write pilot status on bcer-9.0-20261012-e7923a4-ydb (issue #564, slice of #224).
# One flow written by `WRITES=1 rake wire:capture` (host mode, loopback broker), signed on as
# PROV123. The flow first checks BEHOENCX GETVISIT on visit 4 and creates only when its patient
# piece is 4. On this build ^AUPNVSIT(4,0) piece 5 is 4 and the seed's own TIU documents 1-4 sit
# on DFN 4, visit 4. ProgressNote.create itself does not compare the visit's patient with DFN, and
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
# One line per RPC: RPC | status | reason | unproven: <fields or none>

TIU CREATE RECORD | pilot-ready | live capture signed on as PROV123 returned new note IEN 6 for DFN 4 visit 4 title 248; BEHOENCX GETVISIT signed on as PROV123 returned patient 4 for visit 4 before the create; ProgressNote.create reads it as success | unproven: none
TIU LOCK RECORD | pilot-ready | live capture signed on as PROV123 returned 0 (lock held) on note 6; ProgressNote.lock reads it as true | unproven: none
TIU SET DOCUMENT TEXT | pilot-ready | live capture signed on as PROV123 returned 6^1^1 on note 6 for the wrapped two-line note; update_text reads it as success; SETTEXT^TIUSRVPT has no author check, so update_text sends it only after TIU AUTHORIZATION (EDIT RECORD) answers 1, captured live for the author and refused for another user (#614) | unproven: none
TIU GET RECORD TEXT | pilot-ready | live read-back signed on as PROV123 of note 6 matches the note lines row for row after the header (only a wrap-boundary space or hard cut tolerated), each wrapped line within WRAP_WIDTH (80 bytes) | unproven: none
TIU UNLOCK RECORD | pilot-ready | live capture signed on as PROV123 returned 0 on note 6; ProgressNote.unlock reads it as true | unproven: none
TIU SIGN RECORD | not-proven | seed gap: NEW PERSON field 20.4 (electronic signature code) is empty for PROVIDER,TEST (DUZ 200, the PROV123 persona) on this build, so a live sign signed on as PROV123 is refused with 89250005 "incorrect Electronic Signature Code"; the fixture stays routine-cite | unproven: success
