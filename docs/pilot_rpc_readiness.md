# Chart-read pilot status on bcer-9.0-20261012-e7923a4-ydb (issue #224).
# Seed patient DFN 2. rake wire:capture defaults, signed on as SYS123.
# One line per RPC: RPC | status | reason | unproven: <fields or none>

ORWPT ID INFO | partial | ssn, SC%, ward, and room-bed blank for outpatient DFN 2 (USER,TEST, veteran N) under SYS123's division | unproven: room_bed, sc_percent, ssn, ward_location
BEHOPTCX PTINFO | partial | designated team and primary provider blank for DFN 2 under SYS123's division; ssn is FMTSSN's constant mask XXX-XX-XXXX | unproven: designated_team, primary_provider, ssn
BEHOPTPC GETBDP | not-proven | live call for DFN 2 under SYS123's division returned no data rows (empty designated provider in the seed) | unproven: date_raw, label, provider_ien, provider_name, title
BEHOCACV CWAD | pilot-ready | DFN 2 CWAD is "A" on bcer-9.0-20261012-e7923a4-ydb under SYS123's division | unproven: none
ORQQPL LIST | partial | priority, service-connected, and special exposures blank on both of DFN 2's inactive-ICD rows (piece 13 "#") under SYS123's division | unproven: priority, service_connected, special_exposures
ORQQAL LIST | partial | severity blank on DFN 2's penicillin allergy (signs HIVES) under SYS123's division | unproven: severity
ORWPS ACTIVE | not-proven | live call for DFN 2 under SYS123's division returned no data rows (no active medications in the seed) | unproven: active_text
ORQQVI VITALS | partial | qualifiers blank on all four vitals (PU, BP, HT, WT) for DFN 2 under SYS123's division | unproven: qualifiers
