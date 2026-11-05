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
# (#9009020.2) entry 3 has no FILE ROOM PRINTER (.05), so booking answers "No file room
# printer is defined for the chart request." (BSDX07.m:64); (3) PROV123's sign-on division
# is INSTITUTION 1, and no MEDICAL CENTER DIVISION (#40.8) points to it (the fixtures'
# setup.division and setup.medical_center_division_institutions), so $$DIV^BSDU is 0 for
# PROV123 and booking answers the same printer refusal even with (2) fixed -- the ADD
# fixture's persona_probe is that refusal. On the disposable rung the capture creates the
# synthetic resource and sets the ZZNULL device as the printer (its setup.notes say so); it
# adds no RESOURCE USER entry and changes no division.
# One line per RPC: RPC | status | reason | unproven: <effects or none>

BSDX ADD NEW APPOINTMENT | not-proven | proven live signed on as SYS123 (division 7819; appointment 1 at 3261126.09 for DFN 3, every effect read back on #9002018.4 and #2.98), but PROV123's booking is refused with "BSDX07 Error: No file room printer is defined for the chart request." -- seed gap: PROV123's division, INSTITUTION 1, has no #40.8 MEDICAL CENTER DIVISION, so $$DIV^BSDU is 0 | unproven: appointment_id, dpt_appt_clinic, patient, resource, start
BSDX CHECKIN APPOINTMENT | pilot-ready | signed on as PROV123 (DUZ 200), appointment 1 checked in at 3261105.0805; #9002018.4 .03 and the clinic's #44.003 entry (patient 3, field 309) read back that time, both empty just before the call | unproven: none
BSDX CANCEL APPOINTMENT | pilot-ready | signed on as PROV123 (DUZ 200), appointment 2 cancelled type PC with coded reason 5; the reply is an empty ERRORID row (no-data, not proof by itself), and #2.98 reads back status PC, reason 5 and user 200, #9002018.4 .12 a cancel time, none of them set just before the call | unproven: none
BSDX NOSHOW | pilot-ready | signed on as PROV123 (DUZ 200), appointment 3 marked no-show; #9002018.4 .1 reads back 1 and #2.98 status N and user 200 on the patient record, neither set just before the call | unproven: none
