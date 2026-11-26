# frozen_string_literal: true

require "rpms_rpc/api/bmx"

# The BMXNet library's own RPCs, as RpmsRpc::Bmx sends them under BMXRPC,
# recorded as flows as the front desk clerk test role (PROFILE,REG, DUZ 207 on
# this image) on the demo image's panel patient QUEBEC,SAGE (DFN 990017).
# Reads only.
B = RpmsRpc::Bmx
DUZ = "207"
CAPTURE = {
  rpc: "BMX USER", entry_point: "USER^BMXRPC3",
  signed_on_as: "PROFILE,REG (PREG123, the front desk clerk test role's published demo pair)",
  access: "PREG123", verify: "PREG123!!",
  note: "Reads only.",
  flows: {
    "user_name" => { about: "Bmx.user_name(207)", run: -> { B.user_name(DUZ) } },
    "holds_key" => { about: "Bmx.holds_key?(AGZMENU)", run: -> { B.holds_key?("AGZMENU") } },
    "holds_key_not" => { about: "Bmx.holds_key?(AGZMGR)", run: -> { B.holds_key?("AGZMGR") } },
    "facilities" => { about: "Bmx.facilities(207)", run: -> { B.facilities(DUZ) } },
    "version" => { about: "Bmx.version(BMX)", run: -> { B.version("BMX") } },
    "user_keys" => { about: "Bmx.user_keys(207)", run: -> { B.user_keys(DUZ) } },
    "find_patients" => { about: "Bmx.find_patients(QUEBEC,SAGE)", run: -> { B.find_patients("QUEBEC,SAGE") } },
    "recent_visits" => { about: "Bmx.recent_visits(990017, max: 2)", run: -> { B.recent_visits(990_017, max: 2) } },
    "alive" => { about: "Bmx.alive?", run: -> { B.alive? } },
    "patients_from" => { about: "Bmx.patients_from(QUEBEC,SAGE, count: 1)", run: -> { B.patients_from("QUEBEC,SAGE", count: 1) } },
    "banner" => { about: "Bmx.banner(990017)", run: -> { B.banner(990_017) } },
    "chart" => { about: "Bmx.chart(990017)", run: -> { B.chart("990017") } },
    "patient_info" => { about: "Bmx.patient_info(990017)", run: -> { B.patient_info(990_017) } },
    "patient_lookup" => { about: "Bmx.patient_lookup(QUEBEC,SAGE)", run: -> { B.patient_lookup("QUEBEC,SAGE") } },
    "fields" => { about: "Bmx.fields(9999999.03)", run: -> { B.fields(9_999_999.03) } },
    "multiples" => { about: "Bmx.multiples(2)", run: -> { B.multiples(2) } },
    "sql" => { about: "Bmx.sql: the patients named QUEBEC,S...", run: -> { B.sql("SELECT NAME, SEX FROM PATIENT WHERE NAME LIKE 'QUEBEC,S%'") } },
    "sql_columns" => { about: "Bmx.sql_columns", run: -> { B.sql_columns("SELECT NAME, SEX FROM PATIENT") } },
    "files" => { about: "Bmx.files(PATIENT..PATIENTZ)", run: -> { B.files(from: "PATIENT", to: "PATIENTZ") } },
    "find" => { about: "Bmx.find(200, PROFILE,, max: 30)", run: -> { B.find(200, "PROFILE,", max: 30) } }
  }
}.freeze
