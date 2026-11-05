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

# TIU note-write pilot status on bcer-9.0-20261012-e7923a4-ydb (issue #564, slice of #224).
# One flow written by `WRITES=1 rake wire:capture` (host mode, loopback broker), signed on as
# PROV123: ProgressNote.create on seed patient DFN 4, visit 4, title 248 PROGRESS NOTE, then lock,
# update_text (a line over WRAP_WIDTH, #479), the TIU GET RECORD TEXT read-back, and unlock.
# A write is proven only when the gem's public API reads its captured reply as success
# (RpmsRpc::WireCapture.write_evidence?). A refused write is never evidence.
# Failed live while its tests passed: the read-back check split rows on \r?\n, but this build
# separates TIU GET RECORD TEXT rows with a bare \r; fixed in this slice.
# One line per RPC: RPC | status | reason | unproven: <fields or none>

TIU CREATE RECORD | pilot-ready | live capture signed on as PROV123 returned new note IEN 10 for DFN 4 visit 4 title 248; ProgressNote.create reads it as success | unproven: none
TIU LOCK RECORD | pilot-ready | live capture signed on as PROV123 returned 0 (lock held) on note 10; ProgressNote.lock reads it as true | unproven: none
TIU SET DOCUMENT TEXT | pilot-ready | live capture signed on as PROV123 returned 10^1^1 on note 10 for the wrapped two-line note; update_text reads it as success | unproven: none
TIU GET RECORD TEXT | pilot-ready | live read-back signed on as PROV123 of note 10 holds every note line after the header, each wrapped line within WRAP_WIDTH (80 bytes) | unproven: none
TIU UNLOCK RECORD | pilot-ready | live capture signed on as PROV123 returned 0 on note 10; ProgressNote.unlock reads it as true | unproven: none
TIU SIGN RECORD | not-proven | seed gap: NEW PERSON field 20.4 (electronic signature code) is empty for PROVIDER,TEST (DUZ 200, the PROV123 persona) on this build, so a live sign signed on as PROV123 is refused with 89250005 "incorrect Electronic Signature Code"; the fixture stays routine-cite | unproven: success
