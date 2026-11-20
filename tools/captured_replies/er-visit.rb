# frozen_string_literal: true

require "rpms_rpc/api/emergency_room"
require "rpms_rpc/api/ddr_fileman"

# RpmsRpc::EmergencyRoom.visit read on the build as PROVIDER,TEST (rpms-rpc#747).
# The build ships no ER visit, and the stock AMER screens that file one stop on
# YottaDB at discharge (openrpms#1254), so setup files one for DEMO,PATIENT ONE
# (DFN 4) through DDR FILER, the path openrpms#1255 proves stores an ER VISIT
# (#9009080): arrival 21:40 by PRIVATE VEHICLE/WALK IN (#9009083 176), visit type
# UNSCHEDULED (3), CHEST PAIN, ESI 2, triaged by the signed-on user at 21:52,
# disposition HOME (164) at 23:15.
ER_DFN = 4
OTHER_DFN = 5
ER_VISIT = {} # rubocop:disable Style/MutableConstant -- setup records the new IEN for the flows

def file_er_visit(session)
  RpmsRpc.configure { |cfg| cfg.client = session }
  RpmsRpc::ContextScope.scoped(session, RpmsRpc::EmergencyRoom::CONTEXT) do
    values = { ".01" => "3261119.214", ".02" => ER_DFN.to_s, ".05" => "3", ".25" => "176", "1" => "CHEST PAIN",
               ".24" => "2", ".07" => session.duz.to_s, "12.2" => "3261119.2152", "6.1" => "164", "6.2" => "3261119.2315" }
    rows = values.map { |field, value| { file: "9009080", field: field, iens: "+1,", value: value } }
    filed = RpmsRpc::DdrFileman.filer(mode: "ADD", rows: rows)
    abort "setup: DDR FILER did not file the ER visit: #{filed.inspect}" unless filed&.dig(:success)
    ER_VISIT[:ien] = Integer(filed[:iens].fetch(1))
  end
  {}
ensure
  RpmsRpc.reset!
end

CAPTURE = {
  rpc: "DDR GETS ENTRY DATA", entry_point: "GETSC^DDR2",
  signed_on_as: "PROVIDER,TEST (PROV123, a published demo pair)",
  access: "PROV123", verify: "PROV123!!",
  context: "CIAV VUECENTRIC",
  note: "Run on a throwaway container. Setup files one ER VISIT (#9009080) for DFN 4 through DDR FILER " \
        "before the flows run; the build ships none.",
  setup: ->(session) { file_er_visit(session) },
  calls: [],
  flows: {
    "on_file" => { about: "visit(dfn: 4, visit_ien:): the ER visit setup filed",
                   run: -> { RpmsRpc::EmergencyRoom.visit(dfn: ER_DFN, visit_ien: ER_VISIT.fetch(:ien)) } },
    "other_patient" => { about: "visit(dfn: 5, visit_ien:): DFN 4's ER visit asked for as DFN 5's",
                         run: -> { RpmsRpc::EmergencyRoom.visit(dfn: OTHER_DFN, visit_ien: ER_VISIT.fetch(:ien)) } },
    "not_on_file" => { about: "visit(dfn: 4, visit_ien: 999999): an ER visit the build does not have",
                       run: -> { RpmsRpc::EmergencyRoom.visit(dfn: ER_DFN, visit_ien: 999_999) } }
  }
}.freeze
