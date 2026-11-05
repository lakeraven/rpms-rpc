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

# Visit and encounter pilot status on bcer-9.0-20261012-e7923a4-ydb (issue #563, slice of #224).
# Seed patient DFN 2, seed visit IEN 1 at hospital location 6, captured live signed on as PROV123
# (rake wire:capture, host mode, PINNED=1). Grading is the chart-read grading above.
# BEHOENCX CHKVISIT returns one COMPONENT^TEXT row per check whatever the outcome (CV1 overwrites
# the status code, BEHOENCX.m:329-337), so Encounter.open used to report POV missing on visit 1,
# which has one: a mapping that failed live although its tests passed. Fixed in this slice.
# Write rows have no capture (wire:capture never sends a write); they are judged by
# test/live/encounter_visit_live_test.rb and test/live/behavioral_health_save_pcc_visit_live_test.rb.

BEHOENCX GETVISIT | partial | visit 1 for DFN 2 signed on as PROV123 returns location 6, 3260825.09, service category A, patient 2 and locked 0; mapped visit_id is blank (VISIT ID 15001 not set on the seed visit) | unproven: visit_id
BEHOENCX FETCH | partial | CREATE=0 read of visit 1 for DFN 2 signed on as PROV123 returns DEMO PRIMARY CARE, provider 12 and visit 1; room_bed is blank for the outpatient, visit_id is blank (^AUPNVSIT(1,150) not set), and error is set only when the visit does not resolve | unproven: error, room_bed, visit_id
BEHOENCX CHKVISIT | pilot-ready | visit 1 signed on as PROV123 returns POV^Visit has POV and E&M^Visit has no note; Encounter.open now lists only E&M (not checked: no note), since POV is present; visit 1 has no note, so no alert is filed by the call | unproven: none
BEHOENCX FETCH CREATE=1 | not-proven | signed on as PROV123 the create replies "Error Creating Visit": PROV123's NEW PERSON division is institution 1, which has no PCC MASTER CONTROL (#9001000) entry, so FNDVIS sends a blank VISIT TYPE and APCDALV refuses with .03 TYPE OF VISIT MISSING (seed gap, rpms-ops); no V VISIT is written. Signed on as SYS123 (division 7819) the same call created a visit, a second CREATE=1 returned the same IEN, and CREATE=0 found it, but that is not the pilot persona | unproven: locked, visit_id, visit_ien
AMHG CREATE/EDIT VISIT | not-proven | signed on as PROV123 (and SYS123) EN^AMHBHRU refuses with 0~Activity Type Missing! because BehavioralHealth.save_visit cannot file #9002011 .06 activity type, so PCC VISIT LINK .16 stays blank and no PCC visit is created (rpms-rpc API gap, not seed) | unproven: row
