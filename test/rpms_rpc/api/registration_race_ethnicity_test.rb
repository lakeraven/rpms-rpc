# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/registration"
require_relative "../captured_replies"

# Registration.race_ethnicity returns each race and ethnicity with its code
# file's 3 HL7 VALUE, the CDC Race & Ethnicity code a FHIR or HL7 v2 caller
# codes it with (rpms-rpc#830, rpms-ux S-REG-20.2). Each test replays a flow
# the gem ran as PROFILE,REG on the pinned build
# (test/fixtures/captured_replies/registration-race-ethnicity.yml).
class RegistrationRaceEthnicityTest < Minitest::Test
  Reg = RpmsRpc::Registration
  SLUG = "registration-race-ethnicity"

  def teardown
    RpmsRpc.reset!
  end

  def replay(flow, script = CapturedReplies.flow_script(SLUG, flow))
    @flow = flow
    @client = CapturedReplies::ReplayCiaClient.new(script)
    RpmsRpc.configure { |cfg| cfg.client = @client }
  end

  def sent = @client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params] ] }

  def test_a_race_on_file_comes_back_with_its_cdc_code
    replay("on_file")

    read = Reg.race_ethnicity(4)

    assert_equal [ { ien: 2, name: "AMERICAN INDIAN OR ALASKA NATIVE", method: 4, method_name: "UNKNOWN", hl7_value: "1002-5" } ],
                 read[:races]
    assert_equal CapturedReplies.flow_calls(SLUG, "on_file"), sent
  end

  def test_ethnicity_rows_carry_their_hl7_value_too
    replay("on_file")

    read = Reg.race_ethnicity(4)

    assert_equal [ { ien: 2, name: "NOT HISPANIC OR LATINO", method: 1, method_name: "SELF IDENTIFICATION", hl7_value: "2186-5" } ],
                 read[:ethnicities]
  end

  def test_a_code_entry_with_no_hl7_value_is_nil_not_guessed_from_the_name
    replay("legacy_code")

    read = Reg.race_ethnicity(990_011)

    assert_equal [ { ien: 3, name: "WHITE, NOT OF HISPANIC ORIGIN", method: 1, method_name: "SELF IDENTIFICATION", hl7_value: nil } ],
                 read[:races]
    assert_empty read[:ethnicities]
    assert_equal CapturedReplies.flow_calls(SLUG, "legacy_code"), sent
  end

  # The code file's read answered with the build's own refusal: the read
  # raises rather than returning a row without its code.
  def test_a_failed_code_file_read_raises
    script = CapturedReplies.flow_script(SLUG, "on_file")
    script["DDR GETS ENTRY DATA"][1] = CapturedReplies.raw(SLUG, "code_not_on_file")
    replay("on_file", script)

    assert_raises(RpmsRpc::Client::RpcError) { Reg.race_ethnicity(4) }
  end
end
