# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/bmx"
require "rpms_rpc/api/immunization_registry"
require_relative "../captured_replies"

# RpmsRpc::Bmx and the immunization registry reads, on the replies the demo
# image sent (test/fixtures/captured_replies/bmx-library.yml and
# bgovimm-registry.yml, recorded as flows), replayed through CiaClient's own
# reads. The round trips are test/live/bmx_library_reads_live_test.rb and
# immunization_registry_live_test.rb.
class BmxTest < Minitest::Test
  B = RpmsRpc::Bmx
  I = RpmsRpc::Immunization

  def teardown
    RpmsRpc.reset!
  end

  def replay(slug, flow)
    @slug = slug
    @flow = flow
    @client = CapturedReplies::ReplayCiaClient.new(CapturedReplies.flow_script(slug, flow))
    RpmsRpc.configure { |cfg| cfg.client = @client }
  end

  def sent = @client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params] ] }

  def test_each_bmx_read_parses_the_build_reply_and_sends_what_was_recorded
    {
      "user_name" => [ -> { B.user_name("207") }, "PROFILE,REG" ],
      "holds_key" => [ -> { B.holds_key?("AGZMENU") }, true ],
      "holds_key_not" => [ -> { B.holds_key?("AGZMGR") }, false ],
      "facilities" => [ -> { B.facilities("207") }, [ { name: "DEMO IHS CLINIC", ien: 7819, most_recent: true } ] ],
      "version" => [ -> { B.version("BMX") }, { major: 1, minor: 0, build: "3050613.12" } ],
      "user_keys" => [ -> { B.user_keys("207") }, [ "AGZMENU" ] ],
      "alive" => [ -> { B.alive? }, true ],
      "patients_from" => [ -> { B.patients_from("QUEBEC,SAGE", count: 1) }, [ { name: "QUEBEC,SAGE", sex: "F", dob: Date.new(2001, 6, 9) } ] ],
      "patient_lookup" => [ -> { B.patient_lookup("QUEBEC,SAGE") }, [ { dfn: 990_017, name: "QUEBEC,SAGE", hrn: "990017", dob: Date.new(2001, 6, 9) } ] ],
      "sql" => [ -> { B.sql("SELECT NAME, SEX FROM PATIENT WHERE NAME LIKE 'QUEBEC,S%'") }, [ { name: "QUEBEC,SAGE", sex: "FEMALE" } ] ],
      "sql_columns" => [ -> { B.sql_columns("SELECT NAME, SEX FROM PATIENT") }, %w[name sex] ]
    }.each do |flow, (call, expected)|
      replay("bmx-library", flow)
      assert_equal expected, call.call, flow
      assert_equal CapturedReplies.flow_calls("bmx-library", flow), sent, flow
      assert_includes @client.calls, { rpc: :create_context, params: [ "BMXRPC" ] }, "#{flow} binds BMXRPC"
    end
  end

  def test_the_patient_and_schema_reads
    replay("bmx-library", "find_patients")
    assert_equal "INDIAN/ALASKA NATIVE", B.find_patients("QUEBEC,SAGE").first[:classification]
    replay("bmx-library", "recent_visits")
    visit = B.recent_visits(990_017, max: 2).first
    assert_equal [ "OCT 28, 2026@14:00", "DEMO IHS CLINIC", "PROFILE,BH" ], visit.values_at(:timestamp, :location, :provider)
    assert_equal [ [ "BMX FIND VISIT", [ "990017|2" ] ] ], sent
    replay("bmx-library", "banner")
    assert_equal({ dob: "09-Jun-2001", age: "25 years", sex: "Female", chart: "99-00-17", status: nil }, B.banner(990_017))
    replay("bmx-library", "chart")
    assert_equal Date.new(2001, 6, 9), B.chart("990017")[:dob]
    replay("bmx-library", "patient_info")
    assert_equal "Female", B.patient_info(990_017)[:sex]
    replay("bmx-library", "fields")
    assert_includes B.fields(9_999_999.03), { number: ".01", label: "NAME" }
    replay("bmx-library", "multiples")
    assert_includes B.multiples(2), { number: "2.01", name: "ALIAS" }
    replay("bmx-library", "files")
    assert_includes B.files(from: "PATIENT", to: "PATIENTZ"), { name: "PATIENT", number: "9000001" }
    replay("bmx-library", "find")
    assert_includes B.find(200, "PROFILE,", max: 30), { name: "PROFILE,REG" }
  end

  def test_the_immunization_registry_reads
    { "contraindications" => [ -> { I.contraindications.first }, { ien: 1, name: "Fever>104F" } ],
      "state_forecaster_on" => [ -> { I.state_forecaster_on? }, true ],
      "state_forecast_last_run" => [ -> { I.state_forecast_last_run(990_001) }, nil ],
      "duplicates_allowed" => [ -> { I.duplicates_allowed?(104) }, false ],
      "registry_case" => [ -> { I.registry_case(990_001) }, nil ] }.each do |flow, (call, expected)|
      replay("bgovimm-registry", flow)
      expected.nil? ? assert_nil(call.call, flow) : assert_equal(expected, call.call, flow)
      assert_equal CapturedReplies.flow_calls("bgovimm-registry", flow), sent, flow
    end
  end
end
