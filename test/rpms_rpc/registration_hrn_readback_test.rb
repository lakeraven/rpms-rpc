# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/registration"
require_relative "captured_replies"

# Issue #562 / #224: registration must fail closed when AG reports an HRN write
# but #9000001.41 read-back (DDR LISTER) does not confirm it.
#
# Every reply is test/fixtures/captured_replies/registration-hrn-readback.yml,
# captured live as PROFILE,REG: each register flow filed its own synthetic
# patient over CIA, with the duplicate lookup on a BMX session signed on as the
# same user. The fail-closed cases replay a register flow with its read-back
# reply swapped for another real one: the multiple of a patient filed with no
# HRN, another patient's HRN, or FileMan's refusal of an IENS. A transport
# failure on the read-back is raised by the replay itself.
class RegistrationHrnReadbackTest < Minitest::Test
  Reg = RpmsRpc::Registration
  SLUG = "registration-hrn-readback"
  DUZ = "207"

  PATIENTS = {
    "derive" => { name: "SYNTHETIC,DERIVEHRN", dob: Date.new(1902, 3, 1), sex: "F", ssn: "900623001" },
    "temporary" => { name: "SYNTHETIC,TEMPHRN", dob: Date.new(1902, 3, 2), sex: "F", ssn: "900623002", hrn_source: :temporary },
    "given" => { name: "SYNTHETIC,GIVENHRN", dob: Date.new(1902, 3, 3), sex: "F", ssn: "900623003", hrn_source: :given, hrn: "77123" },
    "clerk" => { name: "SYNTHETIC,CLERKHRN", dob: Date.new(1902, 3, 4), sex: "F", ssn: "900623004" }
  }.freeze

  def teardown
    Reg.hrn_mode = Reg::HRN_MODE_DERIVE
    RpmsRpc.reset!
  end

  # The DDR LISTER reply of a flow, to stand in as another flow's read-back.
  def lister_reply(flow)
    CapturedReplies.flow(SLUG, flow).find { |c| c["rpc"] == "DDR LISTER" }.fetch("raw_return").b
  end

  # Replay a register flow on a CIA session, with its duplicate lookup on a
  # BMX session signed on as the same user, and register its patient.
  def register(flow, readback: nil)
    script = CapturedReplies.flow_script(SLUG, flow)
    script["DDR LISTER"] = [ lister_reply(readback) ] if readback
    @session = CapturedReplies::ReplayCiaClient.new(script).signed_on_as(DUZ)
    RpmsRpc.configure { |c| c.client = @session }
    yield @session if block_given?
    Reg.with_lookup_client(lookup(flow)) { Reg.register(PATIENTS.fetch(flow)) }
  end

  def lookup(flow)
    client = CapturedReplies::ReplayBmxClient.new(CapturedReplies.flow_script(SLUG, "lookup_#{flow}"))
    client.instance_variable_set(:@authenticated, true)
    client.instance_variable_set(:@duz, DUZ)
    client.instance_variable_set(:@current_context, RpmsRpc::Agg::CONTEXT)
    client
  end

  def sent = @session.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params] ] }

  def hrn_lister_calls
    @session.calls.select { |c| c[:rpc] == "DDR LISTER" && c[:params].first["FILE"] == "9000001.41" }
  end

  def assert_hrn_readback_lister_fields
    refute_empty hrn_lister_calls, "expected a #9000001.41 DDR LISTER read-back"
    hrn_lister_calls.each do |call|
      assert_equal "@;.02", call[:params].first["FIELDS"],
                   "read-back must suppress .01 so piece 0 is field .02 under every DDR version"
    end
  end

  def refute_message_leaks_phi(message)
    refute_match(/900623001|SYNTHETIC|DERIVEHRN|03\/01\/1902|1902-03-01|77123|T00001|^990057$/, message.to_s)
  end

  def test_derive_hrn_success_requires_matching_9000001_41_readback
    result = register("derive")

    assert result[:success], "expected success only after #9000001.41 confirms HRN 990057"
    assert_equal 990_057, result[:dfn]
    assert_equal "990057", result[:hrn]
    assert_equal 1, hrn_lister_calls.length, "must read #9000001.41 before reporting success"
    assert_hrn_readback_lister_fields
    assert_equal CapturedReplies.flow_calls(SLUG, "derive"), sent
  end

  def test_derive_hrn_empty_multiple_is_hrn_file_failed
    result = register("derive", readback: "no_hrn_on_file")

    assert_equal :hrn_file_failed, result[:error]
    assert_equal 990_057, result[:dfn]
    refute result[:success]
    refute_message_leaks_phi(result[:message])
    assert_hrn_readback_lister_fields
  end

  def test_derive_hrn_mismatch_on_file_is_hrn_file_failed
    result = register("derive", readback: "given")

    assert_equal :hrn_file_failed, result[:error]
    assert_equal 990_057, result[:dfn]
    refute_message_leaks_phi(result[:message])
  end

  def test_derive_hrn_unverified_when_lister_errors
    result = register("derive", readback: "refused_iens")

    assert_equal :hrn_file_failed, result[:error]
    assert_equal 990_057, result[:dfn]
    assert_equal Reg::HRN_UNREADABLE, result[:message]
  end

  def test_temporary_hrn_success_requires_matching_readback
    result = register("temporary")

    assert result[:success]
    assert_equal "T00001", result[:hrn]
    assert_equal 1, hrn_lister_calls.length
    assert_equal CapturedReplies.flow_calls(SLUG, "temporary"), sent
  end

  def test_given_hrn_success_requires_matching_readback
    result = register("given")

    assert result[:success]
    assert_equal "77123", result[:hrn]
    assert_equal 1, hrn_lister_calls.length
    assert_equal CapturedReplies.flow_calls(SLUG, "given"), sent
  end

  def test_clerk_mode_without_hrn_skips_readback
    Reg.hrn_mode = Reg::HRN_MODE_CLERK

    result = register("clerk")

    assert result[:success]
    assert_nil result[:hrn]
    assert_empty hrn_lister_calls
    assert_equal CapturedReplies.flow_calls(SLUG, "clerk"), sent
  end

  [
    RpmsRpc::Client::ConnectionError,
    RpmsRpc::Client::TimeoutError,
    RpmsRpc::Client::ParseError
  ].each do |error_class|
    define_method("test_derive_hrn_#{error_class.name.split('::').last.downcase}_on_readback_is_hrn_file_failed") do
      result = register("derive") do |session|
        session.define_singleton_method(:call_rpc_raw) do |rpc, *params|
          raise error_class, "synthetic #9000001.41 read-back failure" if rpc == "DDR LISTER"

          super(rpc, *params)
        end
      end

      refute result[:success]
      assert_equal :hrn_file_failed, result[:error]
      assert_equal 990_057, result[:dfn]
      assert_equal Reg::HRN_UNREADABLE, result[:message]
      refute_message_leaks_phi(result[:message])
    end
  end
end
