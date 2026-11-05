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
# Tribal enrollment slice (issue #566): persona PROV123, seed patient DFN 2,
# tribe and service-unit IEN 1. Each Tribal read is graded on the API's returned
# keys. List methods are proven by any row. :valid is proven only when both true
# and false were observed.
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
Tribal.enrollment | partial | seed-data gap: .07 TRIBAL ENROLLMENT NO. is blank on every #9000001 entry of the seed, so enrollment_number is empty for DFN 2 signed on as PROV123 while tribe, quantum, classification, eligibility status, and community are populated | unproven: enrollment_number
Tribal.eligibility | pilot-ready | DDR GETS ENTRY DATA for DFN 2 signed on as PROV123 populated eligibility status, eligibility status name, classification IEN, and classification | unproven: none
Tribal.tribe_info | pilot-ready | TRIBE #9999999.03 IEN 1 signed on as PROV123 returned an IEN, name, and code | unproven: none
Tribal.service_unit | pilot-ready | SERVICE UNIT #9999999.22 IEN 1 signed on as PROV123 returned an IEN and name | unproven: none
Tribal.tribes | pilot-ready | DDR LISTER of TRIBE #9999999.03 for names starting with A, signed on as PROV123, returned rows that carry an IEN and a name, so the list method is proven by any row | unproven: none
Tribal.communities | pilot-ready | DDR LISTER of COMMUNITY #9999999.05 for names starting with AT, signed on as PROV123, returned rows that carry an IEN, name, county, and state, so the list method is proven by any row | unproven: none
Tribal.validate | pilot-ready | :valid is proven only when both true and false were observed: DDR VALIDATOR on #9000001 field .07 signed on as PROV123 accepted 12345 and rejected a 40-character value, and internal and external were populated on the accepted value | unproven: none
Registration.update eligibility | pilot-ready | AG Eligibility window via AGG UPDATE PATIENT, read back through DDR GETS ENTRY DATA and Tribal.enrollment by test/live/registration_eligibility_update_live_test.rb on synthetic DFN 990052 as PROV123; seed-data gap: BENEFICIARY #9999999.25 holds only OTHER on this build, so only that classification is proven | unproven: none
