# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/version"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/measurement"

class MeasurementTest < Minitest::Test
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
    script("BGOVMSR SET" => "2001")

    result = RpmsRpc::Measurement.add(DFN, VISIT_IEN, "WT", "82", units: "lbs")
    assert result[:success]
    assert_equal 2001, result[:ien]
  end

  def test_add_dispatches_bgovmsr_set_with_inp_layout
    client = script("BGOVMSR SET" => "2001")

    RpmsRpc::Measurement.add(DFN, VISIT_IEN, "WT", "82", units: "lbs")

    call = client.calls.find { |c| c[:rpc] == "BGOVMSR SET" }
    refute_nil call
    # INP per BGOVMSR.m:104: VIEN^VFIEN^TYPE^VALUE^DATETIME. There is no
    # units piece — units are fixed by the AUTTMSR type (BGOVMSR.m:114-115).
    assert_equal [ "#{VISIT_IEN}^^WT^82^" ], call[:params]
  end

  def test_add_accepts_type_abbreviation
    client = script("BGOVMSR SET" => "2001")

    RpmsRpc::Measurement.add(DFN, VISIT_IEN, "HT", "68", units: "in")

    inp = client.calls.last[:params][0].split("^", -1)
    assert_equal "HT", inp[2],
      "abbreviations resolve through the AUTTMSR B index (BGOVMSR.m:115)"
  end

  def test_add_result_has_exact_gateway_shape
    script("BGOVMSR SET" => "2001")

    result = RpmsRpc::Measurement.add(DFN, VISIT_IEN, "WT", "82", units: "lbs")
    assert_equal %i[success ien raw], result.keys
    assert_equal "2001", result[:raw]
  end

  def test_add_error_string_response_returns_failure_with_raw
    # ERR^BGOUTL(1087) — bad measurement type (BGOVMSR.m:116)
    script("BGOVMSR SET" => "-1087^Invalid measurement type")

    result = RpmsRpc::Measurement.add(DFN, VISIT_IEN, "WT", "82", units: "lbs")
    refute result[:success]
    assert_nil result[:ien]
    assert_equal "-1087^Invalid measurement type", result[:raw]
  end

  def test_add_nil_broker_response_does_not_raise
    client = Object.new
    def client.supports?(*) = true
    def client.call_rpc(*) = nil
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = client }

    result = RpmsRpc::Measurement.add(DFN, VISIT_IEN, "WT", "82", units: "lbs")
    assert_equal({ success: false, ien: nil, raw: nil }, result)
  end

  def test_add_garbage_array_response_does_not_raise
    client = Object.new
    def client.supports?(*) = true
    def client.call_rpc(*) = [ "unexpected", "lines" ]
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = client }

    result = RpmsRpc::Measurement.add(DFN, VISIT_IEN, "WT", "82", units: "lbs")
    refute result[:success]
    assert_nil result[:ien]
  end

  def test_value_required_units_required
    refute RpmsRpc::Measurement.add(DFN, VISIT_IEN, "WT", nil, units: "lbs")[:success]
    refute RpmsRpc::Measurement.add(DFN, VISIT_IEN, "WT", "82", units: "")[:success]
  end

  def test_blank_ids_return_failure
    refute RpmsRpc::Measurement.add(nil, VISIT_IEN, "WT", "82", units: "lbs")[:success]
    refute RpmsRpc::Measurement.add(DFN, nil, "WT", "82", units: "lbs")[:success]
    refute RpmsRpc::Measurement.add(DFN, VISIT_IEN, "", "82", units: "lbs")[:success]
  end
end
