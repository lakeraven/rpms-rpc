# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/version"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/health_factor"

class HealthFactorTest < Minitest::Test
  DFN       = "8791"
  VISIT_IEN = "2090059"

  # Scripted broker: canned response per RPC name, records every call.
  class ScriptedClient
    attr_reader :calls

    def initialize(responses = {})
      @responses = responses
      @calls = []
    end

    def supports?(*) = true

    def call_rpc(rpc_name, *params)
      @calls << { rpc: rpc_name, params: params }
      @responses.fetch(rpc_name, "")
    end
  end

  def teardown
    RpmsRpc.reset!
  end

  def script(responses)
    RpmsRpc.reset!
    client = ScriptedClient.new(responses)
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def test_add_returns_success_with_saved_ien
    script("BGOVHF SET" => "4001")

    result = RpmsRpc::HealthFactor.add(DFN, VISIT_IEN, "77", level: "HEAVY")
    assert result[:success]
    assert_equal 4001, result[:ien]
  end

  def test_add_dispatches_bgovhf_set_with_inp_layout
    client = script("BGOVHF SET" => "4001")

    RpmsRpc::HealthFactor.add(DFN, VISIT_IEN, "77", level: "HEAVY",
      narrative: "1 ppd", provider_duz: "42", quantity: "20")

    call = client.calls.find { |c| c[:rpc] == "BGOVHF SET" }
    refute_nil call
    # INP per BGOVHF.m:44: TYPE^VFIEN^VIEN^SEV^PRV^QTY^COMMENT
    assert_equal [ "77^^#{VISIT_IEN}^HEAVY^42^20^1 ppd" ], call[:params]
  end

  def test_add_error_string_response_returns_failure_with_raw
    # ERR^BGOUTL(1008) — missing HF type (BGOVHF.m:49)
    script("BGOVHF SET" => "-1008^Health factor type not specified")

    result = RpmsRpc::HealthFactor.add(DFN, VISIT_IEN, "77", level: "HEAVY")
    refute result[:success]
    assert_nil result[:ien]
    assert_equal "-1008^Health factor type not specified", result[:raw]
  end

  def test_level_is_required_keyword
    assert_raises(ArgumentError) { RpmsRpc::HealthFactor.add(DFN, VISIT_IEN, "77") }
  end

  def test_blank_args_return_failure
    refute RpmsRpc::HealthFactor.add(nil, VISIT_IEN, "77", level: "HEAVY")[:success]
    refute RpmsRpc::HealthFactor.add(DFN, nil, "77", level: "HEAVY")[:success]
    refute RpmsRpc::HealthFactor.add(DFN, VISIT_IEN, "", level: "HEAVY")[:success]
  end
end
