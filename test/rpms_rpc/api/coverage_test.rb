# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/eligibility"
require "rpms_rpc/api/agg"

begin
  require "rpms_rpc/api/coverage"
rescue LoadError
  # Spec-only branch: a missing implementation must fail assertions, not the suite loader.
  module RpmsRpc
    module Coverage
      EMPTY = { entries: [] }.freeze
      MEDICARE_WINDOW = "Medicare"
      MEDICARE_ELIGIBILITY_WINDOW = "Medicare Eligibility"
      MEDICAID_WINDOW = "Medicaid"
      MEDICAID_ELIGIBILITY_WINDOW = "Medicaid Eligibility"

      def self.for_patient(*) = nil
      def self.medicare_update(*) = nil
      def self.medicaid_update(*) = nil
      def self.add_medicare(*) = nil
      def self.delete_medicare(*) = nil
      def self.add_medicaid(*) = nil
      def self.delete_medicaid(*) = nil
      def self.encode_params(*) = nil
    end
  end
end

# RpmsRpc::Coverage — insurance eligibility (Medicare/Medicaid/private) through
# AGG/BQI RPCs (rpms-rpc#382). Distinct from RpmsRpc::Eligibility (VFC immunization).
class CoverageTest < Minitest::Test
  Cov = RpmsRpc::Coverage
  Agg = RpmsRpc::Agg
  FS = "\x1c" # $C(28) — PARMS delimiter (AGGUPMCR.m:59, AGGUPMCD.m:132)
  RS = "\x1e" # $C(30)
  US = "\x1f" # $C(31)

  MEDICARE_RPC = "AGG UPDATE MEDICARE"       # UPD^AGGUPMCR.m:7
  MEDICAID_RPC = "AGG UPDATE MEDICAID"       # UPD^AGGUPMCD.m:5
  BQI_RPC = "BQI PATIENT INSURANCE"          # GET^BQIPTINS.m:6

  MCR_HEADER = "I00010RESULT^T01024ERROR^I00010RIEN^I00010MIEN#{RS}" # AGGUPMCR.m:25
  MCD_HEADER = "I00010RESULT^T01024ERROR^I00010RIEN^I00010MIEN#{RS}" # AGGUPMCD.m:21
  BQI_HEADER = "T00100INSURANCE_COVERAGE^D00015EFFECTIVE_DATE#{RS}"  # BQIPTINS.m:14

  DFN = 42

  class RecordingClient
    include RpmsRpc::ContextScope

    attr_reader :received_calls, :context_binds

    def initialize(replies = {})
      @replies = replies.transform_keys(&:to_s)
      @received_calls = []
      @context_binds = []
      @current_context = RpmsRpc::MockClient::DEFAULT_CONTEXT
    end

    def create_context(name)
      @context_binds << name
      @current_context = name
      true
    end

    def current_context = @current_context

    def call_rpc_global_array(rpc, *params)
      @received_calls << { rpc: rpc, params: params.map(&:to_s), context: @current_context }
      key = [ rpc, *params.map(&:to_s) ].join("\0")
      @replies[key] || @replies[rpc] || ""
    end
  end

  def setup
    @mock = RpmsRpc.mock!
  end

  def teardown
    RpmsRpc.reset!
  end

  # -- distinct from VFC Eligibility -----------------------------------------

  def test_module_is_not_vfc_eligibility
    refute_equal RpmsRpc::Eligibility, Cov
    assert_equal "RpmsRpc::Coverage", Cov.name
  end

  # -- for_patient (GET^BQIPTINS) --------------------------------------------

  def test_for_patient_parses_active_rows
    body = BQI_HEADER + "MEDICARE PART A^JAN 1, 2026#{RS}#{US}"
    client = RecordingClient.new(BQI_RPC => body)
    RpmsRpc.configure { |c| c.client = client }

    rows = Cov.for_patient(DFN)

    assert_equal [ { coverage: "MEDICARE PART A", effective_on: "JAN 1, 2026" } ], rows[:entries]
  end

  def test_for_patient_empty_when_only_header_and_sentinel
    client = RecordingClient.new(BQI_RPC => BQI_HEADER + US)
    RpmsRpc.configure { |c| c.client = client }

    assert_equal Cov::EMPTY, Cov.for_patient(DFN)
  end

  def test_for_patient_empty_on_nil_or_blank_reply
    client = RecordingClient.new(BQI_RPC => "")
    RpmsRpc.configure { |c| c.client = client }

    assert_equal Cov::EMPTY, Cov.for_patient(DFN)
    assert_equal Cov::EMPTY, Cov.for_patient(DFN, client: RecordingClient.new(BQI_RPC => nil))
  end

  def test_for_patient_invalid_dfn_makes_no_rpc_call
    client = RecordingClient.new
    RpmsRpc.configure { |c| c.client = client }

    [ nil, "", "0", "-1", "abc", "3.5" ].each do |bad|
      assert_equal Cov::EMPTY, Cov.for_patient(bad, client: client)
    end
    assert_empty client.received_calls
  end

  def test_for_patient_binds_bqirpc_and_restores_caller_context
    client = RecordingClient.new(BQI_RPC => BQI_HEADER + US)
    client.create_context("OR CPRS GUI CHART")
    RpmsRpc.configure { |c| c.client = client }

    Cov.for_patient(DFN)

    call = client.received_calls.find { |c| c[:rpc] == BQI_RPC }
    assert_equal "BQIRPC", call[:context]
    assert_equal [ DFN.to_s ], call[:params]
    assert_equal "OR CPRS GUI CHART", client.current_context
    assert_equal [ "OR CPRS GUI CHART", "BQIRPC", "OR CPRS GUI CHART" ], client.context_binds
  end

  # -- medicare_update wire order (UPD^AGGUPMCR.m:7) ------------------------

  def test_medicare_update_sends_dfn_proc_def_mien_parms_under_aggrpc
    row = "1^^#{DFN}^#{RS}#{US}"
    client = RecordingClient.new(MEDICARE_RPC => MCR_HEADER + row)
    RpmsRpc.configure { |c| c.client = client }

    parms = { "AGGMCROI" => "01/01/2026", "AGGMCNUM" => "1EG4TE5MK72" }
    Cov.medicare_update(DFN, proc: "A", definition: Cov::MEDICARE_WINDOW, params: parms, client: client)

    call = client.received_calls.first
    assert_equal MEDICARE_RPC, call[:rpc]
    assert_equal [ DFN.to_s, "A", Cov::MEDICARE_WINDOW, "", "AGGMCROI=01/01/2026#{FS}AGGMCNUM=1EG4TE5MK72" ], call[:params]
    assert_equal Agg::CONTEXT, call[:context]
  end

  def test_medicare_update_success_parses_rien_and_mien
    client = RecordingClient.new(MEDICARE_RPC => MCR_HEADER + "1^^#{DFN}^2#{RS}#{US}")
    RpmsRpc.configure { |c| c.client = client }

    result = Cov.medicare_update(DFN, proc: "A", definition: Cov::MEDICARE_ELIGIBILITY_WINDOW,
                                  params: { "AGGMCESD" => "01/01/2026" }, client: client)

    assert result[:success]
    assert_equal DFN, result[:rien]
    assert_equal "2", result[:mien]
    assert_nil result[:error]
  end

  def test_medicare_update_rejection_surfaces_error_piece
    client = RecordingClient.new(MEDICARE_RPC => MCR_HEADER + "-1^The entry does not exist.^^^#{RS}#{US}")
    RpmsRpc.configure { |c| c.client = client }

    result = Cov.medicare_update(DFN, proc: "D", definition: Cov::MEDICARE_ELIGIBILITY_WINDOW,
                                  mien: "99", client: client)

    refute result[:success]
    assert_equal :coverage_rejected, result[:error]
    assert_match(/does not exist/, result[:message])
  end

  def test_medicare_update_missing_definition_is_not_success
    client = RecordingClient.new(MEDICARE_RPC =>
      MCR_HEADER + "-1^RPC Call Failed: NO SUCH Definition does not exist.^^^#{RS}#{US}")
    RpmsRpc.configure { |c| c.client = client }

    result = Cov.medicare_update(DFN, proc: "A", definition: "NO SUCH", client: client)

    refute result[:success]
    assert_match(/Definition does not exist/, result[:message])
  end

  def test_medicare_update_empty_reply_is_not_success
    client = RecordingClient.new(MEDICARE_RPC => "")
    RpmsRpc.configure { |c| c.client = client }

    assert_nil Cov.medicare_update(DFN, proc: "A", definition: Cov::MEDICARE_WINDOW, client: client)
  end

  def test_medicare_update_header_without_data_row_is_not_success
    client = RecordingClient.new(MEDICARE_RPC => MCR_HEADER + US)
    RpmsRpc.configure { |c| c.client = client }

    result = Cov.medicare_update(DFN, proc: "A", definition: Cov::MEDICARE_WINDOW, client: client)

    refute result[:success]
    assert_equal :coverage_empty_reply, result[:error]
  end

  def test_medicare_update_invalid_dfn_makes_no_rpc_call
    client = RecordingClient.new
    RpmsRpc.configure { |c| c.client = client }

    assert_nil Cov.medicare_update("abc", proc: "A", definition: Cov::MEDICARE_WINDOW, client: client)
    assert_empty client.received_calls
  end

  def test_medicare_update_rejects_delimiter_in_params
    client = RecordingClient.new
    RpmsRpc.configure { |c| c.client = client }

    err = assert_raises(ArgumentError) do
      Cov.medicare_update(DFN, proc: "A", definition: Cov::MEDICARE_WINDOW,
                          params: { "AGGMCNUM" => "1#{FS}2" }, client: client)
    end
    assert_match(/delimiter/, err.message)
    assert_empty client.received_calls
  end

  def test_medicare_update_rejects_caret_in_field_values
    client = RecordingClient.new
    RpmsRpc.configure { |c| c.client = client }

    assert_raises(ArgumentError) do
      Cov.medicare_update(DFN, proc: "E", definition: Cov::MEDICARE_WINDOW,
                          params: { "AGGMCNME" => "BAD^NAME" }, client: client)
    end
    assert_empty client.received_calls
  end

  def test_medicare_update_rejects_invalid_proc_without_calling
    client = RecordingClient.new
    RpmsRpc.configure { |c| c.client = client }

    assert_raises(ArgumentError) { Cov.medicare_update(DFN, proc: "X", definition: Cov::MEDICARE_WINDOW, client: client) }
    assert_empty client.received_calls
  end

  # -- medicaid_update wire order (UPD^AGGUPMCD.m:5) ------------------------

  def test_medicaid_update_sends_dfn_proc_def_rien_mien_parms
    row = "1^^9^3261031#{RS}#{US}"
    client = RecordingClient.new(MEDICAID_RPC => MCD_HEADER + row)
    RpmsRpc.configure { |c| c.client = client }

    Cov.medicaid_update(DFN, proc: "A", definition: Cov::MEDICAID_ELIGIBILITY_WINDOW,
                        record_ien: "9", params: { "AGGMDESD" => "01/01/2026", "AGGMDECV" => "FULL" },
                        client: client)

    call = client.received_calls.first
    assert_equal [ DFN.to_s, "A", Cov::MEDICAID_ELIGIBILITY_WINDOW, "9", "",
                  "AGGMDESD=01/01/2026#{FS}AGGMDECV=FULL" ], call[:params]
    assert_equal Agg::CONTEXT, call[:context]
  end

  def test_medicaid_update_success_parses_record_and_multiple_iens
    client = RecordingClient.new(MEDICAID_RPC => MCD_HEADER + "1^^8^3261031#{RS}#{US}")
    RpmsRpc.configure { |c| c.client = client }

    result = Cov.medicaid_update(DFN, proc: "A", definition: Cov::MEDICAID_ELIGIBILITY_WINDOW,
                                 record_ien: "8", params: { "AGGMDESD" => "10/31/2026" }, client: client)

    assert result[:success]
    assert_equal "8", result[:record_ien]
    assert_equal "3261031", result[:multiple_ien]
  end

  def test_medicaid_delete_with_no_row_is_not_success
    client = RecordingClient.new(MEDICAID_RPC => MCD_HEADER + "-1^The entry does not exist.^^^#{RS}#{US}")
    RpmsRpc.configure { |c| c.client = client }

    result = Cov.medicaid_update(DFN, proc: "D", definition: Cov::MEDICAID_WINDOW,
                                 record_ien: "8", client: client)

    refute result[:success]
  end

  def test_medicaid_update_empty_reply_is_not_success
    client = RecordingClient.new(MEDICAID_RPC => "")
    RpmsRpc.configure { |c| c.client = client }

    assert_nil Cov.medicaid_update(DFN, proc: "A", definition: Cov::MEDICAID_WINDOW, client: client)
  end

  # -- convenience writers ---------------------------------------------------

  def test_add_medicare_files_header_then_eligibility
    client = RecordingClient.new
    recorder = client
    client.define_singleton_method(:call_rpc_global_array) do |rpc, *params|
      recorder.received_calls << { rpc: rpc, params: params.map(&:to_s), context: recorder.current_context }
      case [ rpc, params[2].to_s ]
      when [ MEDICARE_RPC, Cov::MEDICARE_WINDOW ]
        MCR_HEADER + "1^^#{DFN}^#{RS}#{US}"
      when [ MEDICARE_RPC, Cov::MEDICARE_ELIGIBILITY_WINDOW ]
        MCR_HEADER + "1^^#{DFN}^1#{RS}#{US}"
      else
        ""
      end
    end
    RpmsRpc.configure { |c| c.client = client }

    result = Cov.add_medicare(DFN, roi_on: "01/01/2026", name: "ZZCOV,TEST", number: "1EG4TE5MK72",
                              suffix: "A", effective_on: "01/01/2026", client: client)

    assert result[:success]
    assert_equal 2, client.received_calls.count { |c| c[:rpc] == MEDICARE_RPC }
  end

  def test_delete_medicare_requires_eligibility_removed_before_header
    order = []
    client = RecordingClient.new
    client.define_singleton_method(:call_rpc_global_array) do |rpc, *params|
      order << [ params[2].to_s, params[3].to_s, params[1].to_s ] if rpc == MEDICARE_RPC
      MCR_HEADER + "1^^#{DFN}^#{RS}#{US}"
    end
    RpmsRpc.configure { |c| c.client = client }

    Cov.delete_medicare(DFN, eligibility_mien: "1", client: client)

    assert_equal [ [ Cov::MEDICARE_ELIGIBILITY_WINDOW, "1", "D" ], [ Cov::MEDICARE_WINDOW, "", "D" ] ], order
  end

  def test_add_medicaid_creates_record_then_eligibility_row
    client = RecordingClient.new
    recorder = client
    client.define_singleton_method(:call_rpc_global_array) do |rpc, *params|
      recorder.received_calls << { rpc: rpc, params: params.map(&:to_s), context: recorder.current_context }
      if rpc == MEDICAID_RPC && params[2].to_s == Cov::MEDICAID_WINDOW
        MCD_HEADER + "1^^6^#{RS}#{US}"
      elsif rpc == MEDICAID_RPC
        MCD_HEADER + "1^^6^3261031#{RS}#{US}"
      else
        ""
      end
    end
    RpmsRpc.configure { |c| c.client = client }

    result = Cov.add_medicaid(DFN, effective_on: "01/01/2026", coverage: "FULL", client: client)

    assert result[:success]
    assert_equal "6", result[:record_ien]
    elig_call = client.received_calls.find { |c| c[:params][2] == Cov::MEDICAID_ELIGIBILITY_WINDOW }
    assert_equal "6", elig_call[:params][3]
  end
end
