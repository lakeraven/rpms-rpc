# frozen_string_literal: true

require "rpms_rpc/context_scope"
require "rpms_rpc/api/ddr_fileman"

# The calls BehavioralHealth.save_health_factors makes, in its order, on a BH
# visit setup files for synthetic patient DFN 990037, plus the refusals the
# build sends: a lock another session holds, health factor names that are
# inactive, a category or not on file, and AMHG's error reply. rpms-rpc#622.
HF_DDR = RpmsRpc::DdrFileman
HF_DFN = "990037"
HF_NAME = "4PS I HAD DIFFICULTIES DUE TO AOD USE"
HF_TYPE_LISTER = ->(part) { HF_DDR.lister_param(file: "9999999.64", xref: "B", part: part, fields: ".01;.1;.13", flags: "IP", max: "25") }
HF_LOCK = ->(s) { [ HF_DDR.lock_param(node: "^AMHREC(#{s[:rec]})", timeout: 5) ] }

CAPTURE = {
  rpc: "AMHG SAVE HEALTH FACTORS", entry_point: "HF^AMHGSVF",
  signed_on_as: "SYS123 (the build's operator, MANAGER,SYSTEM; DUZ 4), the persona AMHGRPC lets file BH records",
  access: "SYS123", verify: "RPMS.000", context: "CIAV VUECENTRIC",
  personas: {
    other: { access: "SYS123", verify: "RPMS.000", signed_on_as: "SYS123 again, on a second broker session" }
  },
  setup: lambda { |client|
    first = ->(file) { HF_DDR.lister(file: file, fields: ".01", flags: "IP", max: "25")[:entries].first[:ien] }
    RpmsRpc.configure { |cfg| cfg.client = client }
    clinic, type, location, community = %w[40.7 9002012.1 9999999.06 9999999.05].map { |f| first.(f) }
    now = Array(client.call_rpc("ORWU DT", "NOW")).first.to_s
    wire = "A||#{client.duz}|M|#{clinic}|#{type}||#{now}|#{location}|W|#{community}|#{HF_DFN}||||"
    reply = RpmsRpc::ContextScope.scoped(client, "AMHGRPC") { client.call_rpc_global_array("AMHG SAVE VISIT", wire) }
    rec = reply.to_s.split("\x1e")[1].to_s
    raise "AMHG SAVE VISIT made no visit: #{reply.inspect}" unless rec.match?(/\A[1-9]\d*\z/)

    { rec: rec }
  },
  note: "Setup files one BH visit (AMHG SAVE VISIT, as the live spec does); its IEN is in each capture's inputs. " \
        "The calls replay one edit-mode save of one health factor in the gem's order: lock, visit pre-read, " \
        "type pre-read, AMHG SAVE HEALTH FACTORS, read-back, unlock. Synthetic patient and text only.",
  calls: [
    { name: "lock", rpc: "DDR LOCK/UNLOCK NODE", inputs: HF_LOCK, about: "the save locks ^AMHREC(visit)" },
    { name: "lock_held_elsewhere", as: :other, rpc: "DDR LOCK/UNLOCK NODE",
      inputs: ->(s) { [ HF_DDR.lock_param(node: "^AMHREC(#{s[:rec]})", timeout: 1) ] },
      about: "a second session asks for the lock the first holds" },
    { name: "visit", rpc: "DDR GETS ENTRY DATA",
      inputs: ->(s) { [ HF_DDR.gets_entry_param(file: "9002011", iens: "#{s[:rec]},", fields: ".08;1112", flags: "I") ] },
      about: "the visit pre-read: patient and signature date" },
    { name: "type_active", rpc: "DDR LISTER", inputs: [ HF_TYPE_LISTER.(HF_NAME) ], about: "an active FACTOR entry" },
    { name: "type_inactive", rpc: "DDR LISTER", inputs: [ HF_TYPE_LISTER.("0-FOOD AND EXERCISE") ],
      about: "an inactive FACTOR entry (.13 = 1)" },
    { name: "type_category", rpc: "DDR LISTER", inputs: [ HF_TYPE_LISTER.("4PS") ],
      about: "a CATEGORY entry, listed with the longer FACTOR names it prefixes" },
    { name: "type_not_on_file", rpc: "DDR LISTER", inputs: [ HF_TYPE_LISTER.("SYN FACTOR NOT ON FILE") ],
      about: "a name no entry has" },
    { name: "save_name_not_on_file", context: "AMHGRPC", inputs: ->(s) { [ "E|#{s[:rec]}|SYN FACTOR NOT ON FILE~MINIMAL~1~SYN HF|#{HF_DFN}" ] },
      about: "a factor name the type file does not hold: AMHG's error reply" },
    { name: "save", inputs: ->(s) { [ "E|#{s[:rec]}|#{HF_NAME}~MINIMAL~1~SYN HF|#{HF_DFN}" ] },
      about: "edit mode, one factor" },
    { name: "readback", context: "CIAV VUECENTRIC", rpc: "DDR LISTER",
      inputs: ->(s) {
        [ HF_DDR.lister_param(file: "9002011.08", xref: "AD", part: s[:rec], screen: "I $P(^(0),U,3)=#{s[:rec]}",
                              fields: ".01E;.02;.03;.04E;.06;81101", flags: "IP", max: "25") ]
      },
      about: "the visit's health factors after the save" },
    { name: "unlock", rpc: "DDR LOCK/UNLOCK NODE", inputs: ->(s) { [ HF_DDR.unlock_param(node: "^AMHREC(#{s[:rec]})") ] },
      about: "the save releases the lock" }
  ]
}.freeze
