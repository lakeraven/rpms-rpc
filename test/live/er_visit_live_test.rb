# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/emergency_room"
require "rpms_rpc/api/patient"
require "rpms_rpc/fileman_date_parser"
require "rpms_rpc/server_clock"

# EmergencyRoom.visit reads an ER VISIT (#9009080) back through DDR GETS ENTRY
# DATA (rpms-rpc#747). The build ships no ER visit, and the stock AMER screens
# that file one stop on YottaDB at discharge (openrpms#1254), so the spec files
# one through DDR FILER, the path openrpms#1255 proves stores an ER VISIT, then
# reads it back typed. A visit asked for under another patient, and an IEN the
# build does not have, read as nil.
#
# WRITES against a disposable local container only.
class ErVisitLiveTest < LiveSpec::Test
  runs_as "PROV123"
  writes!

  DFN = 990_012       # LIMA,REESE, a synthetic seed patient; unused by other live specs
  OTHER_DFN = 990_013 # MIKE,SKYLER
  VISIT_TYPE = 3      # ER OPTIONS (#9009083) UNSCHEDULED
  PRIVATE_VEHICLE = 176
  HOME = 164

  def fm(time) = RpmsRpc::FilemanDateParser.format_datetime(time)

  def test_an_er_visit_filed_on_the_build_reads_back_typed
    refute_nil RpmsRpc::Patient.find(DFN), "DFN #{DFN} must exist on this disposable container's seed data"
    arrived = minute(RpmsRpc::ServerClock.now - 3600)
    triaged = arrived + 720
    departed = arrived + 5700
    ien = file_visit(".01" => fm(arrived), ".02" => DFN, ".05" => VISIT_TYPE, ".25" => PRIVATE_VEHICLE,
                     "1" => "CHEST PAIN", ".24" => 2, ".07" => client.duz, "12.2" => fm(triaged),
                     "6.1" => HOME, "6.2" => fm(departed))

    visit = RpmsRpc::EmergencyRoom.visit(dfn: DFN, visit_ien: ien)

    refute_nil visit, "ER VISIT #{ien} did not read back for DFN #{DFN}"
    assert_equal ien, visit[:ien]
    assert_equal DFN, visit[:dfn]
    assert_equal arrived, visit[:arrived_at]
    assert_equal({ ien: PRIVATE_VEHICLE, name: "PRIVATE VEHICLE/WALK IN" }, visit[:mode_of_transport])
    assert_equal({ ien: VISIT_TYPE, name: "UNSCHEDULED" }, visit[:visit_type])
    assert_equal "CHEST PAIN", visit[:presenting_complaint]
    assert_equal 2, visit[:esi]
    assert_equal client.duz.to_i, visit.dig(:triage_nurse, :ien)
    assert_equal triaged, visit[:triage_nurse_at]
    assert_equal({ ien: HOME, name: "HOME" }, visit[:disposition])
    assert_equal departed, visit[:departed_at]
    assert_nil visit[:pcc_visit_ien], "a FileMan-filed ER VISIT carries no PCC visit (openrpms#1255)"

    assert_nil RpmsRpc::EmergencyRoom.visit(dfn: OTHER_DFN, visit_ien: ien), "another patient's ER visit must not read back"
    assert_nil RpmsRpc::EmergencyRoom.visit(dfn: DFN, visit_ien: 999_999_999), "an IEN the build does not have reads as nil"
  end

  private

  def minute(time) = Time.new(time.year, time.month, time.day, time.hour, time.min, 0)

  def file_visit(values)
    rows = values.map { |field, value| { file: "9009080", field: field, iens: "+1,", value: value.to_s } }
    filed = RpmsRpc::ContextScope.scoped(client, RpmsRpc::EmergencyRoom::CONTEXT) do
      RpmsRpc::DdrFileman.filer(mode: "ADD", rows: rows)
    end
    flunk "setup: DDR FILER did not file the ER visit: #{filed.inspect}" unless filed&.dig(:success)
    Integer(filed[:iens].fetch(1))
  end
end
