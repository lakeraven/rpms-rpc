# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/version"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/exam_component"

class ExamComponentTest < Minitest::Test
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
    script("BGOVEXAM SET" => "3001")

    result = RpmsRpc::ExamComponent.add(DFN, VISIT_IEN, "28", finding: "N")
    assert result[:success]
    assert_equal 3001, result[:ien]
  end

  def test_add_dispatches_bgovexam_set_with_inp_layout
    client = script("BGOVEXAM SET" => "3001")

    RpmsRpc::ExamComponent.add(DFN, VISIT_IEN, "28", finding: "N",
      narrative: "no abnormalities", provider_duz: "42")

    call = client.calls.find { |c| c[:rpc] == "BGOVEXAM SET" }
    refute_nil call
    # INP per BGOVEXAM.m:103-104: VXAMIEN^EXAMIEN^VIEN^PRV^RESULT^COMMENT^
    # EVENTDT^LOCIEN^OTHERLOC^HIST^DFN
    assert_equal [ "^28^#{VISIT_IEN}^42^N^no abnormalities^^^^^#{DFN}" ], call[:params]
  end

  def test_add_error_string_response_returns_failure_with_raw
    # ERR^BGOUTL(1077) — missing exam type (BGOVEXAM.m:113)
    script("BGOVEXAM SET" => "-1077^Exam type not specified")

    result = RpmsRpc::ExamComponent.add(DFN, VISIT_IEN, "28", finding: "N")
    refute result[:success]
    assert_nil result[:ien]
    assert_equal "-1077^Exam type not specified", result[:raw]
  end

  def test_blank_finding_required
    refute RpmsRpc::ExamComponent.add(DFN, VISIT_IEN, "28", finding: "")[:success]
    refute RpmsRpc::ExamComponent.add(DFN, VISIT_IEN, "28", finding: nil)[:success]
  end

  def test_blank_args_return_failure
    refute RpmsRpc::ExamComponent.add(nil, VISIT_IEN, "28", finding: "N")[:success]
    refute RpmsRpc::ExamComponent.add(DFN, nil, "28", finding: "N")[:success]
    refute RpmsRpc::ExamComponent.add(DFN, VISIT_IEN, "", finding: "N")[:success]
  end
end
