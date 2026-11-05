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
# Tribal enrollment slice (issue #566): persona PROV123, seed patient DFN 2.
# Each Tribal read is graded on the API's returned keys. A whole-value UNKNOWN
# (any case) is filler, not evidence. A validator "^" is the failed
# input-transform marker and proves neither internal nor external. Tribe info
# and service unit are called with IEN 1; that IEN is echoed from the request,
# not returned by the build, so it is not wire evidence. A list :ien is proven
# only by a positive integer on a row. List methods are proven by any row.
# :valid is proven only when both true and false were observed.
# test/live/registration_eligibility_update_live_test.rb failed live although its
# hermetic tests passed: it looked up classification INDIAN/ALASKA NATIVE, absent
# on this build; fixed in the spec commit.

ORWPT ID INFO | partial | mapped ssn, sc_percent, ward_location, and room_bed are nil for outpatient DFN 2 (USER,TEST, sex M, veteran N, dob 1985-05-05) signed on as PROV123 | unproven: room_bed, sc_percent, ssn, ward_location
BEHOPTCX PTINFO | partial | mapped mrn, designated_team, and primary_provider are nil for DFN 2 signed on as PROV123 (blank $$HRN for that sign-on division); ssn maps to FMTSSN's constant mask XXX-XX-XXXX, populated on the wire but not evidence | unproven: designated_team, mrn, primary_provider, ssn
BEHOPTPC GETBDP | not-proven | live call for DFN 2 signed on as PROV123 returned no data rows (empty designated provider in the seed), so no mapped label, provider_name, provider_ien, title, or date_raw | unproven: date_raw, label, provider_ien, provider_name, title
ORWPT CWAD | not-proven | there is no live ORWPT CWAD capture on bcer-9.0-20261012-e7923a4-ydb yet (routine-cited only; main moved brief_header's CWAD read from BEHOCACV CWAD to ORWPT CWAD), so persona PROV123 has not proven brief_header flags | unproven: ad_flag, allergy_flag
ORQQPL LIST | partial | both of DFN 2's rows (IEN 1 *TYPE 2 DIABETES MELLITUS, IEN 2 *ESSENTIAL HYPERTENSION) signed on as PROV123 are inactive-ICD (piece 13 "#"), so mapped icd_code and transcribed are nil and inactive_icd is true on every row (false was not mapped); piece 4 is $$ICDDX "Invalid Code (not found in the ICD-9-CM system)", which is not code-shaped and is never an icd_code; priority, service_connected, and special_exposures are blank | unproven: icd_code, inactive_icd, priority, service_connected, special_exposures, transcribed
ORQQAL LIST | partial | mapped severity is nil on DFN 2's penicillin allergy (IEN 1, signs HIVES) signed on as PROV123 | unproven: severity
ORWPS ACTIVE | not-proven | live call for DFN 2 signed on as PROV123 returned no data rows (no active medications in the seed), so Medication.active_for_patient proved none of order_id, type, name, status, stop_date, instructions, or comments | unproven: comments, instructions, name, order_id, status, stop_date, type
ORQQVI VITALS | partial | mapped qualifiers is nil on all four vitals (PU 82, BP 142/88, HT 70, WT 214) for DFN 2 signed on as PROV123 | unproven: qualifiers
Tribal.enrollment | partial | seed-data gaps for DFN 2 signed on as PROV123: .07 TRIBAL ENROLLMENT NO. is blank on every seed patient, so enrollment_number is empty; field 1118 community is the UNKNOWN filler, not a community. Tribe, quantum, classification, and eligibility status are populated. The seed gaps are tracked as lakeraven/rpms-ops#1079 | unproven: community, enrollment_number
Tribal.eligibility | pilot-ready | DDR GETS ENTRY DATA for DFN 2 signed on as PROV123 populated eligibility status C, name CHS & DIRECT, classification IEN 1, and classification OTHER | unproven: none
Tribal.tribe_info | pilot-ready | TRIBE #9999999.03 looked up at the requested IEN 1, signed on as PROV123, returned name OTHER and code 998 | unproven: none
Tribal.service_unit | pilot-ready | SERVICE UNIT #9999999.22 looked up at the requested IEN 1, signed on as PROV123, returned name NON SERVICE UNIT | unproven: none
Tribal.tribes | pilot-ready | DDR LISTER of TRIBE #9999999.03 for Tribal.tribes(part: "OTHER"), signed on as PROV123, returned one row with positive IEN 1 and name OTHER, so the list method is proven by any row | unproven: none
Tribal.communities | pilot-ready | DDR LISTER of COMMUNITY #9999999.05 for Tribal.communities(part: "STONEHAM"), signed on as PROV123, returned a row with positive IEN 10663, name STONEHAM, county MIDDLESEX, and state MASSACHUSETTS, so the list method is proven by any row | unproven: none
Tribal.validate | pilot-ready | :valid is proven only when both true and false were observed: DDR VALIDATOR on #9000001 field .07 signed on as PROV123 accepted 12345 (internal and external populated) and rejected a 40-character value whose internal is the "^" marker | unproven: none
Registration.update eligibility | not-proven | AG Eligibility window via AGG UPDATE PATIENT, read back through DDR GETS ENTRY DATA and Tribal.enrollment by test/live/registration_eligibility_update_live_test.rb on synthetic DFN 990052 as PROV123; classification is proven only by filing BENEFICIARY #9999999.25 IEN 1 OTHER, the one entry on this build. Live run claimed, not sealed: run 928e66253ea07736 (2026-11-05, bcer-9.0-20261012-e7923a4-ydb) was reported passing but was a TEST= filtered run, which the harness never records (test/live/live_helper.rb write_summary prints NOT RECORDED for a filtered run), so no LiveSummary JSON exists. The row is graded pilot-ready only from a committed harness LiveSummary JSON of a full PROV123 rake test:live run on the pinned build plus its sha256 sidecar | unproven: blood_quantum, classification, eligibility_status, enrollment_number, tribe, tribe_quantum

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
