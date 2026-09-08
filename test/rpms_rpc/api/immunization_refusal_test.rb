# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/version"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/immunization_refusal"

class ImmunizationRefusalTest < Minitest::Test
  DFN = "8791"

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

  def test_record_success_on_empty_reply
    # REFSET2^BGOUTL2 returns "" on success (BGOUTL2.m:126-129); no IEN
    # comes back on the wire.
    script("BGOREF SET" => "")

    result = RpmsRpc::ImmunizationRefusal.record(DFN, "17", reason_ien: "3")
    assert result[:success]
    assert_nil result[:ien]
  end

  def test_record_dispatches_bgoref_set_with_immunization_type
    client = script("BGOREF SET" => "")

    RpmsRpc::ImmunizationRefusal.record(DFN, "17", reason_ien: "3",
      narrative: "parental refusal", refusal_date: "3260908", provider_duz: "42")

    call = client.calls.find { |c| c[:rpc] == "BGOREF SET" }
    refute_nil call
    # INP per BGOREF.m:4-5: REFIEN^TYPE^ITEMIEN^DFN^DATE^COMMENT^PRV^REASON;
    # type "IMMUNIZATION" per BGOVIMM2.m:100.
    assert_equal [ "^IMMUNIZATION^17^#{DFN}^3260908^parental refusal^42^3" ], call[:params]
  end

  def test_record_defaults_refusal_date_to_today
    client = script("BGOREF SET" => "")

    RpmsRpc::ImmunizationRefusal.record(DFN, "17", reason_ien: "3")

    date_piece = client.calls.last[:params][0].split("^", -1)[4]
    assert_match(/\A\d{7}\z/, date_piece, "refusal date defaults to today in FileMan form")
  end

  def test_record_error_reply_is_failure
    # ERR^BGOUTL(1001) — patient not found (BGOREF.m:13)
    script("BGOREF SET" => "-1001^Patient not found")

    result = RpmsRpc::ImmunizationRefusal.record(DFN, "17", reason_ien: "3")
    refute result[:success]
    assert_equal "-1001^Patient not found", result[:raw]
  end

  def test_record_nil_broker_response_is_failure
    client = Object.new
    def client.supports?(*) = true
    def client.call_rpc(*) = nil
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = client }

    result = RpmsRpc::ImmunizationRefusal.record(DFN, "17", reason_ien: "3")
    refute result[:success], "broker silence must not read as a filed refusal"
  end

  def test_reasons_lists_refusal_reason_iens
    RpmsRpc.mock! do |m|
      m.seed_keyed_collection(:refusal_reasons, "IMMUNIZATION", [
        { ien: "3", text: "Parental decision" },
        { ien: "5", text: "Religious exemption" }
      ])
    end

    rows = RpmsRpc::ImmunizationRefusal.reasons
    assert_equal 2, rows.length
    assert_equal "3", rows.first[:ien]
    assert_equal "Parental decision", rows.first[:text]
  end

  def test_reason_ien_is_required_keyword
    assert_raises(ArgumentError) { RpmsRpc::ImmunizationRefusal.record(DFN, "17") }
  end

  def test_blank_args_return_failure
    refute RpmsRpc::ImmunizationRefusal.record(nil, "17", reason_ien: "3")[:success]
    refute RpmsRpc::ImmunizationRefusal.record(DFN, "", reason_ien: "3")[:success]
    refute RpmsRpc::ImmunizationRefusal.record(DFN, "17", reason_ien: nil)[:success]
  end
end
