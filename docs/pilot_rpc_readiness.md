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
# Pointing PROV123's division at 7819 on a disposable container made both HRN filing
# and free-text find work (seed-data gap, rpms-ops seed issue to file).
# Free-text find (Patient.lookup "USER,TEST") returns the header only as PROV123 and
# finds DFN 2 as SYS123; HRN find (123456) and the possible-match name branch work as
# PROV123. COMM and MOMDN columns come only when ^AGFAC(DUZ(2),0) piece 11 is Y
# AND ALL=1 (AGGPTLKP.m:175, 207), so they are absent for PROV123's missing division.

AGG LOOKUP PATIENTS | partial | live possible-match capture signed on as PROV123 returned DFN 2 (USER,TEST, HRN 123456-DIC, DOB MAY 5,1985, sens NO, inactive N); ssn, dod and alias are blank for that seed patient, and community and mothers_maiden_name are not sent without an ^AGFAC entry for PROV123's division; free-text name find returns no rows as PROV123 (seed-data gap) | unproven: alias, community, dod, mothers_maiden_name, ssn_raw
AGG ADD NEW PATIENT | not-proven | creates the chart as PROV123, but a given HRN riding the create was not on #9000001.41 afterwards (PROV123's division is a missing INSTITUTION); register now fails closed with :hrn_file_failed; live-proven as SYS123 only | unproven: hrn
AGG UPDATE PATIENT | not-proven | the derive (HRN := DFN) update answered success as PROV123 while #9000001.41 stayed empty; register now fails closed with :hrn_file_failed; live-proven as SYS123 only | unproven: hrn
AGG GET TEMP PAT HRN | not-proven | returns the next T-number as PROV123, but the update filing it left #9000001.41 empty; register now fails closed with :hrn_file_failed; live-proven as SYS123 only | unproven: hrn
