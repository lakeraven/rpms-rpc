# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/version"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/pov"

class PovTest < Minitest::Test
  DFN       = "8791"
  VISIT_IEN = "2090059"
  ICD       = "I10"

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
    script("BGOVPOV SET" => "9001")

    result = RpmsRpc::Pov.add(DFN, VISIT_IEN, ICD, narrative: "Essential hypertension")
    assert result[:success]
    assert_equal 9001, result[:ien]
  end

  def test_add_dispatches_bgovpov_set_with_single_inp_param
    client = script("BGOVPOV SET" => "9001")

    RpmsRpc::Pov.add(DFN, VISIT_IEN, ICD, narrative: "Essential hypertension")

    call = client.calls.find { |c| c[:rpc] == "BGOVPOV SET" }
    refute_nil call
    inp = call[:params][0].split("^", -1)
    assert_equal VISIT_IEN, inp[1], "Visit IEN is INP piece 2 (BGOVPOV.m:298)"
    assert_equal DFN, inp[3], "Patient IEN is INP piece 4 (BGOVPOV.m:303)"
    assert_equal "Essential hypertension", inp[4], "Prov Text is INP piece 5 (BGOVPOV.m:285)"
    assert_equal ICD, inp[7], "ICD code is INP piece 8 (BGOVPOV.m:286)"
  end

  def test_add_with_primary_modifier_marks_inp_piece_9_p
    client = script("BGOVPOV SET" => "9001")

    RpmsRpc::Pov.add(DFN, VISIT_IEN, ICD, narrative: "primary dx", modifiers: { primary: true })

    inp = client.calls.last[:params][0].split("^", -1)
    assert_equal "P", inp[8], "primary marker is INP piece 9 (BGOVPOV.m:286)"
  end

  def test_add_with_secondary_modifier_marks_inp_piece_9_s
    client = script("BGOVPOV SET" => "9001")

    RpmsRpc::Pov.add(DFN, VISIT_IEN, ICD, narrative: "secondary dx", modifiers: { secondary: true })

    inp = client.calls.last[:params][0].split("^", -1)
    assert_equal "S", inp[8], "secondary marker is INP piece 9 (BGOVPOV.m:286)"
  end

  def test_add_with_injury_cause_modifier_rides_inj_formal
    client = script("BGOVPOV SET" => "9001")

    RpmsRpc::Pov.add(DFN, VISIT_IEN, ICD, narrative: "ankle pain", modifiers: { injury_cause: "W01.0" })

    call = client.calls.last
    assert_equal "W01.0", call[:params][2].split("^", -1)[0],
      "Cause DX is INJ piece 1, the third formal (BGOVPOV.m:288,291)"
    refute_includes call[:params][0], "W01.0",
      "injury cause must not leak into INP"
  end

  def test_add_pins_full_inp_shape
    client = script("BGOVPOV SET" => "9001")

    RpmsRpc::Pov.add(DFN, VISIT_IEN, ICD,
      narrative: "Essential hypertension",
      modifiers: { primary: true, snomed_ct: "38341003", provider_duz: "42" })

    call = client.calls.last
    assert_equal "BGOVPOV SET", call[:rpc]
    # INP per BGOVPOV.m:285-286: VPOVIEN^VIEN^PROBIEN^DFN^PROVTEXT^DESCCT^
    # SNOMED^ICD^PRI^PRV^ASTHMA^NORM^LAT^FRAC; QUAL and INJ ride formals 2-3.
    assert_equal [
      "^#{VISIT_IEN}^^#{DFN}^Essential hypertension^^38341003^#{ICD}^P^42^^^^",
      "",
      ""
    ], call[:params]
  end

  def test_add_result_has_exact_gateway_shape
    script("BGOVPOV SET" => "9001")

    result = RpmsRpc::Pov.add(DFN, VISIT_IEN, ICD, narrative: "Essential hypertension")
    assert_equal %i[success ien raw], result.keys
    assert_equal "9001", result[:raw]
  end

  def test_add_error_string_response_returns_failure_with_raw
    # CHKVISIT^BGOUTL error shape (BGOUTL.m:283-284)
    script("BGOVPOV SET" => "-1003^Visit entry does not exist")

    result = RpmsRpc::Pov.add(DFN, VISIT_IEN, ICD, narrative: "Essential hypertension")
    refute result[:success]
    assert_nil result[:ien]
    assert_equal "-1003^Visit entry does not exist", result[:raw]
  end

  def test_add_nil_broker_response_does_not_raise
    client = Object.new
    def client.supports?(*) = true
    def client.call_rpc(*) = nil
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = client }

    result = RpmsRpc::Pov.add(DFN, VISIT_IEN, ICD, narrative: "Essential hypertension")
    assert_equal({ success: false, ien: nil, raw: nil }, result)
  end

  def test_add_garbage_array_response_does_not_raise
    client = Object.new
    def client.supports?(*) = true
    def client.call_rpc(*) = [ "unexpected", "lines" ]
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = client }

    result = RpmsRpc::Pov.add(DFN, VISIT_IEN, ICD, narrative: "Essential hypertension")
    refute result[:success]
    assert_nil result[:ien]
  end

  def test_narrative_is_required_keyword
    assert_raises(ArgumentError) { RpmsRpc::Pov.add(DFN, VISIT_IEN, ICD) }
  end

  def test_blank_args_return_failure
    refute RpmsRpc::Pov.add(nil, VISIT_IEN, ICD, narrative: "x")[:success]
    refute RpmsRpc::Pov.add(DFN, nil, ICD, narrative: "x")[:success]
    refute RpmsRpc::Pov.add(DFN, VISIT_IEN, "", narrative: "x")[:success]
  end
end
