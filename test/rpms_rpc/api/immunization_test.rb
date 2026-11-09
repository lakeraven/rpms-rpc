# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/immunization"
require_relative "../captured_replies"

# Immunization.text_summary reads the BGOVIMM PROFILE replies a fresh rpms-ydb
# container sent (test/fixtures/captured_replies/bgovimm-profile.yml),
# replayed through CiaClient. rpms-rpc#656: the read is the patient's
# Immunization Profile, keyed by DFN, and a package error is never a summary.
# test/live/immunization_profile_live_test.rb proves the call live.
class ImmunizationTest < Minitest::Test
  SLUG = "bgovimm-profile"
  RPC = "BGOVIMM PROFILE"
  NOT_IN_REGISTER = [
    "This patient is not in the Immunization Register.",
    "The Immserve Profile cannot be stored and displayed",
    "if the patient is not in the Register."
  ].join("\n").freeze

  def teardown
    RpmsRpc.reset!
  end

  def replay(name)
    client = CapturedReplies::ReplayCiaClient.new(RPC => [ CapturedReplies.raw(SLUG, name) ])
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def sent(name) = CapturedReplies.file(SLUG).fetch("captures").find { |c| c["name"] == name }.fetch("inputs")

  def test_a_patient_not_in_the_register_reads_the_packages_message
    client = replay("not_in_register")

    assert_equal NOT_IN_REGISTER, RpmsRpc::Immunization.text_summary("4")
    assert_equal [ { rpc: RPC, params: sent("not_in_register") } ], client.calls,
                 "text_summary sends the patient's DFN to BGOVIMM PROFILE, nothing else"
  end

  def test_a_package_error_raises_and_is_never_a_summary
    replay("registered_no_profile")

    error = assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Immunization.text_summary("2") }
    assert_includes error.message, "Imm/Serve Patient Profile not provided"
    assert_includes error.message, "#307"
  end

  def test_an_invalid_dfn_reaches_no_wire
    client = replay("not_in_register")

    [ nil, "", "0", "-1" ].each { |dfn| assert_nil RpmsRpc::Immunization.text_summary(dfn) }
    assert_empty client.calls
  end
end
