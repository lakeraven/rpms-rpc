# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/patient"
require "rpms_rpc/api/procedure"
require "rpms_rpc/fileman_date_parser"

# Procedure.add files a CPT on a visit through BEHOENPC SAVE (SAVE^BEHOENPC),
# the encounter write VueCentric uses (rpms-rpc#524, #645). It is in CIAV
# VUECENTRIC, the option CIA sign-on binds.
#
# The spec files today's visit for a synthetic patient with a BEHOENPC SAVE of
# its own (as encounter_save_behoenpc_live_test.rb does), adds a CPT to it with
# Procedure.add, and reads the new V CPT (#9000010.18) back with DDR. It then
# checks that a CPT the build cannot resolve and a visit named with another
# patient file nothing.
#
# WRITES against a disposable local container only.
class ProcedureAddLiveTest < LiveSpec::Test
  writes!

  DFN = 990_054 # a synthetic seed patient; unused by other live specs
  OTHER_DFN = 990_055
  CLINIC = "DEMO PRIMARY CARE"
  CPT = "A0021"
  CPT_FILE = "9000010.18"

  def test_add_files_a_v_cpt_on_the_visit_read_back_with_ddr
    assert_synthetic_patient!(DFN)
    duz = client.duz.to_s
    visit = file_visit!(duz)
    now = server_now

    added = RpmsRpc::Procedure.add(DFN, visit, CPT, quantity: 2)
    assert added[:success], "Procedure.add answered #{added.inspect}"
    row = RpmsRpc::DdrFileman.gets_entry(file: CPT_FILE, iens: "#{added[:ien]},", fields: ".01;.02;.03;.16;1216;1217", flags: "IE")
    flunk "DDR GETS on V CPT #{added[:ien]} failed: #{row.inspect}" if row.nil? || row[:error]
    f = row[:fields]
    assert_equal CPT, f.dig(".01", :external), "V CPT #{added[:ien]} .01 is not the CPT sent"
    assert_equal DFN.to_s, f.dig(".02", :internal), "V CPT #{added[:ien]} .02 is not the patient"
    assert_equal visit, f.dig(".03", :internal), "V CPT #{added[:ien]} .03 is not the visit"
    assert_equal "2", f.dig(".16", :internal), "V CPT #{added[:ien]} .16 is not the quantity sent"
    assert_equal duz, f.dig("1217", :internal), "V CPT #{added[:ien]} was not entered by the signed-on user"
    entered = RpmsRpc::FilemanDateParser.parse_datetime(f.dig("1216", :internal))
    assert entered && entered >= now, "V CPT #{added[:ien]} 1216 #{f.dig('1216', :internal).inspect} is not this call's"

    count = cpt_rows_on(visit).size
    assert_equal :not_filed, RpmsRpc::Procedure.add(DFN, visit, "NOTACPT")[:error]
    assert_equal :wrong_patient, RpmsRpc::Procedure.add(OTHER_DFN, visit, CPT)[:error]
    assert_equal count, cpt_rows_on(visit).size, "a refused add filed a V CPT on visit #{visit}"

    puts "\n#{persona}: Procedure.add filed V CPT #{added[:ien]} (#{CPT} x2) on visit #{visit}, DFN #{DFN}"
  end

  private

  # Today's visit for DFN at CLINIC, filed by BEHOENPC SAVE with the user as
  # primary provider; its IEN is the V PROVIDER row's .03.
  def file_visit!(duz)
    loc = clinic_ien!
    when_fm = Array(client.call_rpc("ORWU DT", "NOW")).first.to_s[0, 12]
    pcc = { 1 => "HDR^0^^#{loc};#{when_fm};A", 2 => "VST^DT^#{when_fm}", 3 => "VST^PT^#{DFN}",
            4 => "VST^HL^#{loc}", 5 => "VST^VC^A", 6 => "PRV^#{duz}^^^^1" }
    reply = Array(client.call_rpc("BEHOENPC SAVE", pcc, "0", loc.to_s)).map(&:to_s)
    assert_equal [ "0" ], reply, "BEHOENPC SAVE did not file the visit: #{reply.inspect}"
    listed = RpmsRpc::DdrFileman.lister(file: "9000010.06", fields: ".01;.02;.03", flags: "IP", max: "*")
    flunk "DDR LISTER on V PROVIDER failed: #{listed.inspect}" if listed.nil? || listed[:error]
    mine = listed[:entries].select { |e| e[:pieces][0] == duz && e[:pieces][1] == DFN.to_s }
    flunk "no V PROVIDER for DUZ #{duz} on DFN #{DFN}" if mine.empty?
    mine.last[:pieces][2]
  end

  def cpt_rows_on(visit)
    listed = RpmsRpc::DdrFileman.lister(file: CPT_FILE, fields: ".03", flags: "IP", max: "*")
    flunk "DDR LISTER on V CPT failed: #{listed.inspect}" if listed.nil? || listed[:error]
    listed[:entries].select { |e| e[:pieces][0] == visit }
  end

  def clinic_ien!
    listed = RpmsRpc::DdrFileman.lister(file: "44", fields: ".01", flags: "IP", from: CLINIC[0..-2], part: CLINIC, max: "1")
    row = listed && !listed[:error] && listed[:entries].find { |e| e[:pieces].first == CLINIC }
    flunk "no #{CLINIC} in HOSPITAL LOCATION (#44): is this the pinned image?" unless row
    row[:ien]
  end

  def assert_synthetic_patient!(dfn)
    refute_nil RpmsRpc::Patient.find(dfn), "DFN #{dfn} must exist on this disposable container's seed data"
  end

  def server_now
    value = Array(client.call_rpc("ORWU DT", "NOW")).first.to_s
    now = RpmsRpc::FilemanDateParser.parse_datetime(value) || flunk("ORWU DT NOW did not yield a FileMan datetime: #{value.inspect}")
    Time.new(now.year, now.month, now.day, now.hour, now.min, 0)
  end
end
