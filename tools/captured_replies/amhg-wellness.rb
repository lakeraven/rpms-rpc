# frozen_string_literal: true

require "rpms_rpc/context_scope"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/behavioral_health/wellness"

# The calls BehavioralHealth::Wellness makes, in its order, for one screening
# save and then one measurement save on a BH visit setup files for synthetic
# patient DFN 990045, plus the refusals and errors the build sends: a lock
# another session holds, a visit and a provider not on file, and AMHG's
# replies for a record not on file. rpms-rpc#622.
WL_DDR = RpmsRpc::DdrFileman
WL_DFN = "990045"
WL_VISIT_FIELDS = ".08;1112;1401;1402;1403;1404;1405;1406;1407;1408;1409;1410;1501;1601;1701;1901;2001"
WL_COMMENT = "Synthetic alcohol screening note"
WL_VISIT = ->(s) { [ WL_DDR.gets_entry_param(file: "9002011", iens: "#{s[:rec]},", fields: WL_VISIT_FIELDS, flags: "I") ] }
WL_PROVIDER = ->(ien) { [ WL_DDR.gets_entry_param(file: "200", iens: "#{ien},", fields: ".01", flags: "I") ] }
# The 19-piece wire save_screening builds when alcohol is the one screening on file.
WL_SCREENING = lambda { |rec|
  filed = Hash.new("").merge("1403" => "N", "1404" => "4", "1601" => WL_COMMENT)
  filed = %w[1401 1402 1403 1404 1405 1406 1407 1408 1409 1410 1501 1601 1701 1901 2001].to_h { |f| [ f, filed[f] ] }
  RpmsRpc::BehavioralHealth::Wellness.send(:screening_parameter, rec, filed)
}

CAPTURE = {
  rpc: "AMHG SAVE SCREENING", entry_point: "SCREEN^AMHGSVF",
  signed_on_as: "SYS123 (the build's operator, MANAGER,SYSTEM; DUZ 4), the persona AMHGRPC lets file BH records",
  access: "SYS123", verify: "RPMS.000", context: "CIAV VUECENTRIC",
  personas: {
    other: { access: "SYS123", verify: "RPMS.000", signed_on_as: "SYS123 again, on a second broker session" }
  },
  setup: lambda { |client|
    first = ->(file) { WL_DDR.lister(file: file, fields: ".01", flags: "IP", max: "25")[:entries].first[:ien] }
    RpmsRpc.configure { |cfg| cfg.client = client }
    clinic, type, location, community = %w[40.7 9002012.1 9999999.06 9999999.05].map { |f| first.(f) }
    now = Array(client.call_rpc("ORWU DT", "NOW")).first.to_s
    wire = "A||#{client.duz}|M|#{clinic}|#{type}||#{now}|#{location}|W|#{community}|#{WL_DFN}||||"
    reply = RpmsRpc::ContextScope.scoped(client, "AMHGRPC") { client.call_rpc_global_array("AMHG SAVE VISIT", wire) }
    rec = reply.to_s.split("\x1e")[1].to_s
    raise "AMHG SAVE VISIT made no visit: #{reply.inspect}" unless rec.match?(/\A[1-9]\d*\z/)

    { rec: rec }
  },
  note: "Setup files one BH visit (AMHG SAVE VISIT, as the live spec does); its IEN is in each capture's inputs. " \
        "The screening save files alcohol NEGATIVE with provider DUZ 4; the measurement save files PHQ9 14. " \
        "999999 is an IEN no visit or user has. Synthetic patient and text only.",
  calls: [
    { name: "lock", rpc: "DDR LOCK/UNLOCK NODE", inputs: ->(s) { [ WL_DDR.lock_param(node: "^AMHREC(#{s[:rec]})", timeout: 5) ] },
      about: "the save locks ^AMHREC(visit)" },
    { name: "lock_held_elsewhere", as: :other, rpc: "DDR LOCK/UNLOCK NODE",
      inputs: ->(s) { [ WL_DDR.lock_param(node: "^AMHREC(#{s[:rec]})", timeout: 1) ] },
      about: "a second session asks for the lock the first holds" },
    { name: "visit_before", rpc: "DDR GETS ENTRY DATA", inputs: WL_VISIT, about: "the visit pre-read, nothing screened yet" },
    { name: "visit_not_on_file", rpc: "DDR GETS ENTRY DATA",
      inputs: [ WL_DDR.gets_entry_param(file: "9002011", iens: "999999,", fields: WL_VISIT_FIELDS, flags: "I") ],
      about: "a visit IEN not on file" },
    { name: "provider", rpc: "DDR GETS ENTRY DATA", inputs: WL_PROVIDER.("4"), about: "the provider, on file 200" },
    { name: "provider_not_on_file", rpc: "DDR GETS ENTRY DATA", inputs: WL_PROVIDER.("999999"),
      about: "a provider IEN not on file 200" },
    { name: "save_screening", context: "AMHGRPC", inputs: ->(s) { [ WL_SCREENING.(s[:rec]) ] },
      about: "alcohol NEGATIVE, the other four screenings blank" },
    { name: "save_screening_not_on_file", inputs: [ WL_SCREENING.("999999") ],
      about: "the same screening for a visit not on file: AMHG's error reply" },
    { name: "visit_after_screening", context: "CIAV VUECENTRIC", rpc: "DDR GETS ENTRY DATA", inputs: WL_VISIT,
      about: "the visit read after the screening write" },
    { name: "save_measurements", context: "AMHGRPC", rpc: "AMHG SAVE MEASUREMENTS",
      inputs: ->(s) { [ "A|#{s[:rec]}|PHQ9~~14~4|#{WL_DFN}" ] }, about: "PHQ9 14, provider DUZ 4, mode A" },
    { name: "save_measurements_not_on_file", rpc: "AMHG SAVE MEASUREMENTS", inputs: [ "A|999999|PHQ9~~14~4|#{WL_DFN}" ],
      about: "measurements for a visit not on file: the build answers that IEN, as if filed" },
    { name: "visit_after_measurements", context: "CIAV VUECENTRIC", rpc: "DDR GETS ENTRY DATA", inputs: WL_VISIT,
      about: "the visit read after the measurement write" },
    { name: "msr_read", context: "AMHGRPC", rpc: "AMHG GET VISIT MSR DATA ENTRY", inputs: ->(s) { [ s[:rec] ] },
      about: "the visit's measurements after the write" },
    { name: "unlock", context: "CIAV VUECENTRIC", rpc: "DDR LOCK/UNLOCK NODE",
      inputs: ->(s) { [ WL_DDR.unlock_param(node: "^AMHREC(#{s[:rec]})") ] }, about: "the save releases the lock" }
  ]
}.freeze
