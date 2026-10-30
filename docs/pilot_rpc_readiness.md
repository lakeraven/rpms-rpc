# Chart-read pilot status on bcer-9.0-20261012-e7923a4-ydb (issue #224).
# Seed patient DFN 2. rake wire:capture defaults, signed on as SYS123.
# Status is what the committed fixtures map to: a field is proven only when a
# mapped value is present, a boolean only when both true and false were mapped,
# and each BEHOCACV CWAD letter proves only its own flag.
# One line per RPC: RPC | status | reason | unproven: <fields or none>

ORWPT ID INFO | partial | mapped ssn, sc_percent, ward_location, and room_bed are nil for outpatient DFN 2 (USER,TEST, sex M, veteran N, dob 1985-05-05) under SYS123's division | unproven: room_bed, sc_percent, ssn, ward_location
BEHOPTCX PTINFO | partial | mapped designated_team and primary_provider are nil for DFN 2 under SYS123's division; ssn maps to FMTSSN's constant mask XXX-XX-XXXX, populated on the wire but not evidence | unproven: designated_team, primary_provider, ssn
BEHOPTPC GETBDP | not-proven | live call for DFN 2 under SYS123's division returned no data rows (empty designated provider in the seed), so no mapped label, provider_name, provider_ien, title, or date_raw | unproven: date_raw, label, provider_ien, provider_name, title
BEHOCACV CWAD | partial | DFN 2 CWAD scalar is "A" on bcer-9.0-20261012-e7923a4-ydb under SYS123's division, which proves allergy_flag only; C, W, and D were not observed, so crisis_flag, warning_flag, and ad_flag are unproven | unproven: ad_flag, crisis_flag, warning_flag
ORQQPL LIST | partial | both of DFN 2's rows (IEN 1 *TYPE 2 DIABETES MELLITUS, IEN 2 *ESSENTIAL HYPERTENSION) are inactive-ICD (piece 13 "#"), so mapped icd_code and transcribed are nil and inactive_icd is true on every row (false was not mapped); piece 4 is $$ICDDX "Invalid Code (not found in the ICD-9-CM system)", which is never an icd_code; priority, service_connected, and special_exposures are blank | unproven: icd_code, inactive_icd, priority, service_connected, special_exposures, transcribed
ORQQAL LIST | partial | mapped severity is nil on DFN 2's penicillin allergy (IEN 1, signs HIVES) under SYS123's division | unproven: severity
ORWPS ACTIVE | not-proven | live call for DFN 2 under SYS123's division returned no data rows (no active medications in the seed), so active_text has no mapped value | unproven: active_text
ORQQVI VITALS | partial | mapped qualifiers is nil on all four vitals (PU 82, BP 142/88, HT 70, WT 214) for DFN 2 under SYS123's division | unproven: qualifiers
