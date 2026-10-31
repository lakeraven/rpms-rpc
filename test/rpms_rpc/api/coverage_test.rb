# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/eligibility"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/coverage"
require "rpms_rpc/api/agg"

# RpmsRpc::Coverage — insurance eligibility (Medicare/Medicaid/private) through
# AGG/BQI RPCs (rpms-rpc#382). Distinct from RpmsRpc::Eligibility (VFC immunization).
#
# Panel round 1 (pinned AGGUPMCR.m / AGGUPMCD.m): row-scoped deletes; header
# removal only via delete_medicare_record when #9000003.11 has no rows; partial-add
# rollback; fail-closed BQI reads; MM/DD/YYYY dates; AGG field allowlists.
class CoverageTest < Minitest::Test
  Cov = RpmsRpc::Coverage
  Agg = RpmsRpc::Agg
  Ddr = RpmsRpc::DdrFileman
  FS = "\x1c" # $C(28) — PARMS delimiter (AGGUPMCR.m:59, AGGUPMCD.m:132)
  RS = "\x1e" # $C(30)
  US = "\x1f" # $C(31)

  MEDICARE_RPC = "AGG UPDATE MEDICARE"       # UPD^AGGUPMCR.m:7
  MEDICAID_RPC = "AGG UPDATE MEDICAID"       # UPD^AGGUPMCD.m:5
  BQI_RPC = "BQI PATIENT INSURANCE"          # GET^BQIPTINS.m:6

  MCR_HEADER = "I00010RESULT^T01024ERROR^I00010RIEN^I00010MIEN#{RS}" # AGGUPMCR.m:25
  MCD_HEADER = "I00010RESULT^T01024ERROR^I00010RIEN^I00010MIEN#{RS}" # AGGUPMCD.m:21
  BQI_HEADER = "T00100INSURANCE_COVERAGE^D00015EFFECTIVE_DATE#{RS}"  # BQIPTINS.m:14

  CMS_EXAMPLE_MBI = "1EG4TE5MK73"
  MEDICARE_FILE = "9000003"
  MEDICARE_ELIG_FILE = "9000003.11"
  MEDICAID_FILE = "9000004"

  # ^AGG(9009068.3) parameter names for each window (AGGUPMCR / AGGUPMCD).
  MEDICARE_HEADER_FIELDS = %w[AGGMCROI AGGMCNME AGGMCNUM AGGMCSUF].freeze
  MEDICARE_ELIGIBILITY_FIELDS = %w[AGGMCESD AGGMCCOV AGGMCEDD AGGMCETM].freeze
  MEDICAID_HEADER_FIELDS = %w[].freeze
  MEDICAID_ELIGIBILITY_FIELDS = %w[AGGMDESD AGGMDECV AGGMDEDD AGGMDETM].freeze

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

    def call_rpc(rpc, *params)
      @received_calls << { rpc: rpc, params: params, context: @current_context }
      text = @replies[[ rpc, params.first.to_s ].join("\0")] || @replies[rpc]
      return [] if text.nil?

      text.is_a?(Array) ? text : text.to_s.split(/\r?\n/)
    end

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

  def test_for_patient_nil_when_reply_lacks_typed_header_line
    client = RecordingClient.new(BQI_RPC => "NOT_A_BQI_HEADER#{RS}#{US}")
    RpmsRpc.configure { |c| c.client = client }

    assert_nil Cov.for_patient(DFN)
  end

  def test_for_patient_nil_when_reply_carries_error_marker
    body = "T01024ERROR^Patient not found#{RS}#{US}"
    client = RecordingClient.new(BQI_RPC => body)
    RpmsRpc.configure { |c| c.client = client }

    assert_nil Cov.for_patient(DFN)
  end

  def test_for_patient_nil_on_blank_reply
    client = RecordingClient.new(BQI_RPC => "")
    RpmsRpc.configure { |c| c.client = client }

    assert_nil Cov.for_patient(DFN)
    assert_nil Cov.for_patient(DFN, client: RecordingClient.new(BQI_RPC => nil))
  end

  def test_for_patient_invalid_dfn_makes_no_rpc_call
    client = RecordingClient.new
    RpmsRpc.configure { |c| c.client = client }

    [ nil, "", "0", "-1", "abc", "3.5" ].each do |bad|
      assert_nil Cov.for_patient(bad, client: client)
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

    parms = { "AGGMCROI" => "01/01/2026", "AGGMCNUM" => CMS_EXAMPLE_MBI }
    Cov.medicare_update(DFN, proc: "A", definition: Cov::MEDICARE_WINDOW, params: parms, client: client)

    call = client.received_calls.first
    assert_equal MEDICARE_RPC, call[:rpc]
    assert_equal [ DFN.to_s, "A", Cov::MEDICARE_WINDOW, "", "AGGMCROI=01/01/2026#{FS}AGGMCNUM=#{CMS_EXAMPLE_MBI}" ], call[:params]
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

  def test_medicare_update_rejects_unknown_param_before_wire
    client = RecordingClient.new
    RpmsRpc.configure { |c| c.client = client }

    err = assert_raises(ArgumentError) do
      Cov.medicare_update(DFN, proc: "A", definition: Cov::MEDICARE_WINDOW,
                          params: { "NOT_ON_WINDOW" => "x" }, client: client)
    end
    assert_match(/NOT_ON_WINDOW|unknown|allow/i, err.message)
    assert_empty client.received_calls
  end

  def test_medicare_update_rejects_non_calendar_date_before_wire
    client = RecordingClient.new
    RpmsRpc.configure { |c| c.client = client }

    assert_raises(ArgumentError) do
      Cov.medicare_update(DFN, proc: "A", definition: Cov::MEDICARE_WINDOW,
                          params: { "AGGMCROI" => "02/30/2026" }, client: client)
    end
    assert_empty client.received_calls
  end

  def test_medicare_update_restores_context_when_rpc_raises
    client = RecordingClient.new
    client.create_context("OR CPRS GUI CHART")
    RpmsRpc.configure { |c| c.client = client }

    def client.call_rpc_global_array(*)
      raise RpmsRpc::Client::RpcError, "boom"
    end

    assert_raises(RpmsRpc::Client::RpcError) do
      Cov.medicare_update(DFN, proc: "A", definition: Cov::MEDICARE_WINDOW, client: client)
    end
    assert_equal "OR CPRS GUI CHART", client.current_context
  end

  # -- medicaid_update wire order (UPD^AGGUPMCD.m:5) --------------------------

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

  def test_medicaid_update_empty_reply_is_not_success
    client = RecordingClient.new(MEDICAID_RPC => "")
    RpmsRpc.configure { |c| c.client = client }

    assert_nil Cov.medicaid_update(DFN, proc: "A", definition: Cov::MEDICAID_WINDOW, client: client)
  end

  def test_medicaid_update_rejects_unknown_param_before_wire
    client = RecordingClient.new
    RpmsRpc.configure { |c| c.client = client }

    assert_raises(ArgumentError) do
      Cov.medicaid_update(DFN, proc: "A", definition: Cov::MEDICAID_ELIGIBILITY_WINDOW,
                          record_ien: "1", params: { "BOGUS" => "1" }, client: client)
    end
    assert_empty client.received_calls
  end

  def test_medicaid_update_restores_context_when_rpc_raises
    client = RecordingClient.new
    client.create_context("OR CPRS GUI CHART")
    RpmsRpc.configure { |c| c.client = client }

    def client.call_rpc_global_array(*)
      raise RpmsRpc::Client::RpcError, "boom"
    end

    assert_raises(RpmsRpc::Client::RpcError) do
      Cov.medicaid_update(DFN, proc: "A", definition: Cov::MEDICAID_WINDOW, client: client)
    end
    assert_equal "OR CPRS GUI CHART", client.current_context
  end

  # -- identifier validation (before the wire) --------------------------------

  def test_delete_medicare_rejects_bad_eligibility_mien_before_wire
    client = RecordingClient.new
    RpmsRpc.configure { |c| c.client = client }

    [ "", "0", "-1", "1.5", "abc" ].each do |bad|
      assert_raises(ArgumentError) { Cov.delete_medicare(DFN, eligibility_mien: bad, client: client) }
    end
    assert_empty client.received_calls
  end

  def test_delete_medicaid_rejects_bad_record_or_eligibility_ien_before_wire
    client = RecordingClient.new
    RpmsRpc.configure { |c| c.client = client }

    [ [ "", "1" ], [ "0", "1" ], [ "9", "" ], [ "9", "0" ], [ "9", "-2" ], [ "9", "x" ] ].each do |record, mult|
      assert_raises(ArgumentError) do
        Cov.delete_medicaid(DFN, record_ien: record, eligibility_mien: mult, client: client)
      end
    end
    assert_empty client.received_calls
  end

  def test_add_medicare_rejects_bad_dates_before_wire
    client = RecordingClient.new
    RpmsRpc.configure { |c| c.client = client }

    assert_raises(ArgumentError) do
      Cov.add_medicare(DFN, roi_on: "13/01/2026", name: "ZZ", number: CMS_EXAMPLE_MBI,
                       effective_on: "01/01/2026", client: client)
    end
    assert_empty client.received_calls
  end

  # -- delete_medicare: one eligibility row only (AGGUPMCR PROC D + MIEN) ---

  def test_delete_medicare_sends_one_eligibility_row_delete
    client = RecordingClient.new(MEDICARE_RPC => MCR_HEADER + "1^^#{DFN}^#{RS}#{US}")
    RpmsRpc.configure { |c| c.client = client }

    Cov.delete_medicare(DFN, eligibility_mien: "3", client: client)

    agg = client.received_calls.select { |c| c[:rpc] == MEDICARE_RPC }
    assert_equal 1, agg.size
    assert_equal [ DFN.to_s, "D", Cov::MEDICARE_ELIGIBILITY_WINDOW, "3", "" ], agg.first[:params]
  end

  # -- delete_medicare_record: header only when #9000003.11 is empty --------

  def test_delete_medicare_record_refuses_when_eligibility_rows_remain
    assert_respond_to Cov, :delete_medicare_record, "rpms-rpc#382"
    client = medicare_client_with_lister("[Data]\n1^row\n")
    RpmsRpc.configure { |c| c.client = client }

    result = Cov.delete_medicare_record(DFN, client: client)

    refute result[:success]
    assert_equal :eligibility_rows_remain, result[:error]
    assert_empty client.received_calls.select { |c| c[:rpc] == MEDICARE_RPC }
  end

  def test_delete_medicare_record_deletes_header_when_no_eligibility_rows
    assert_respond_to Cov, :delete_medicare_record, "rpms-rpc#382"
    client = medicare_client_with_lister("[Data]\n")
    client.define_singleton_method(:call_rpc_global_array) do |rpc, *params|
      client.received_calls << { rpc: rpc, params: params.map(&:to_s), context: client.current_context }
      MCR_HEADER + "1^^#{DFN}^#{RS}#{US}" if rpc == MEDICARE_RPC
    end
    RpmsRpc.configure { |c| c.client = client }

    result = Cov.delete_medicare_record(DFN, client: client)

    assert result[:success]
    lister = client.received_calls.find { |c| c[:rpc] == "DDR LISTER" }
    refute_nil lister
    assert_includes lister[:params].join, MEDICARE_ELIG_FILE
    header_del = client.received_calls.find { |c| c[:rpc] == MEDICARE_RPC }
    assert_equal [ DFN.to_s, "D", Cov::MEDICARE_WINDOW, "", "" ], header_del[:params]
  end

  # -- delete_medicaid: one row delete; billed rows fail closed ---------------

  def test_delete_medicaid_sends_one_eligibility_row_delete
    client = RecordingClient.new(MEDICAID_RPC => MCD_HEADER + "1^^6^99#{RS}#{US}")
    seed_medicaid_owner!(client, record_ien: "6", patient_dfn: DFN)
    RpmsRpc.configure { |c| c.client = client }

    result = Cov.delete_medicaid(DFN, record_ien: "6", eligibility_mien: "99", client: client)

    assert result[:success]
    agg = client.received_calls.select { |c| c[:rpc] == MEDICAID_RPC }
    assert_equal 1, agg.size
    assert_equal [ DFN.to_s, "D", Cov::MEDICAID_ELIGIBILITY_WINDOW, "6", "99", "" ], agg.first[:params]
  end

  def test_delete_medicaid_refuses_when_record_is_not_patients
    client = RecordingClient.new
    seed_medicaid_owner!(client, record_ien: "6", patient_dfn: 99)
    RpmsRpc.configure { |c| c.client = client }

    result = Cov.delete_medicaid(DFN, record_ien: "6", eligibility_mien: "1", client: client)

    refute_nil result, "delete_medicaid must answer with a result hash"
    refute result[:success]
    assert_equal :record_not_patients, result[:error]
    assert_empty client.received_calls.select { |c| c[:rpc] == MEDICAID_RPC }
  end

  def test_delete_medicaid_surfaces_billed_eligibility_without_override
    billed = MCD_HEADER + "-1^WARNING: This member has outstanding claims.^^^#{RS}#{US}"
    client = RecordingClient.new(MEDICAID_RPC => billed)
    seed_medicaid_owner!(client, record_ien: "6", patient_dfn: DFN)
    RpmsRpc.configure { |c| c.client = client }

    result = Cov.delete_medicaid(DFN, record_ien: "6", eligibility_mien: "1", client: client)

    refute result[:success]
    assert_equal :billed_eligibility, result[:error]
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
    seed_medicare_absent!(client)
    RpmsRpc.configure { |c| c.client = client }

    result = Cov.add_medicare(DFN, roi_on: "01/01/2026", name: "ZZCOV,TEST", number: CMS_EXAMPLE_MBI,
                              suffix: "A", effective_on: "01/01/2026", client: client)

    assert result[:success]
    assert_equal 2, client.received_calls.count { |c| c[:rpc] == MEDICARE_RPC }
  end

  def test_add_medicare_fails_when_eligibility_returns_blank_mien
    client = RecordingClient.new
    recorder = client
    client.define_singleton_method(:call_rpc_global_array) do |rpc, *params|
      recorder.received_calls << { rpc: rpc, params: params.map(&:to_s), context: recorder.current_context }
      case [ rpc, params[2].to_s ]
      when [ MEDICARE_RPC, Cov::MEDICARE_WINDOW ]
        MCR_HEADER + "1^^#{DFN}^#{RS}#{US}"
      when [ MEDICARE_RPC, Cov::MEDICARE_ELIGIBILITY_WINDOW ]
        MCR_HEADER + "1^^#{DFN}^#{RS}#{US}"
      else
        ""
      end
    end
    seed_medicare_absent!(client)
    RpmsRpc.configure { |c| c.client = client }

    result = Cov.add_medicare(DFN, roi_on: "01/01/2026", name: "ZZCOV,TEST", number: CMS_EXAMPLE_MBI,
                              effective_on: "01/01/2026", client: client)

    refute result[:success]
  end

  def test_add_medicare_rolls_back_new_header_when_eligibility_fails
    client = RecordingClient.new
    recorder = client
    client.define_singleton_method(:call_rpc_global_array) do |rpc, *params|
      recorder.received_calls << { rpc: rpc, params: params.map(&:to_s), context: recorder.current_context }
      case [ rpc, params[2].to_s, params[1].to_s ]
      when [ MEDICARE_RPC, Cov::MEDICARE_WINDOW, "A" ]
        MCR_HEADER + "1^^#{DFN}^#{RS}#{US}"
      when [ MEDICARE_RPC, Cov::MEDICARE_ELIGIBILITY_WINDOW, "A" ]
        MCR_HEADER + "-1^Bad effective date.^^^#{RS}#{US}"
      when [ MEDICARE_RPC, Cov::MEDICARE_WINDOW, "D" ]
        MCR_HEADER + "1^^#{DFN}^#{RS}#{US}"
      else
        ""
      end
    end
    seed_medicare_absent!(client)
    key = ddr_lister_reply_key(file: MEDICARE_ELIG_FILE, fields: "@;.01", flags: "IP", part: DFN.to_s)
    client.instance_eval { @replies[key] = "[Data]\n" }
    RpmsRpc.configure { |c| c.client = client }

    result = Cov.add_medicare(DFN, roi_on: "01/01/2026", name: "ZZCOV,TEST", number: CMS_EXAMPLE_MBI,
                              effective_on: "01/01/2026", client: client)

    refute result[:success]
    assert_equal :eligibility_failed, result[:error]
    assert_equal true, result[:rolled_back]
    header_delete = client.received_calls.find do |c|
      c[:rpc] == MEDICARE_RPC && c[:params][1] == "D" && c[:params][2] == Cov::MEDICARE_WINDOW
    end
    refute_nil header_delete
  end

  def test_add_medicare_leaves_preexisting_header_when_eligibility_fails
    client = RecordingClient.new
    recorder = client
    client.define_singleton_method(:call_rpc_global_array) do |rpc, *params|
      recorder.received_calls << { rpc: rpc, params: params.map(&:to_s), context: recorder.current_context }
      case [ rpc, params[2].to_s, params[1].to_s ]
      when [ MEDICARE_RPC, Cov::MEDICARE_WINDOW, "A" ]
        MCR_HEADER + "1^^#{DFN}^#{RS}#{US}"
      when [ MEDICARE_RPC, Cov::MEDICARE_ELIGIBILITY_WINDOW, "A" ]
        MCR_HEADER + "-1^Bad effective date.^^^#{RS}#{US}"
      else
        ""
      end
    end
    seed_medicare_present!(client)
    RpmsRpc.configure { |c| c.client = client }

    result = Cov.add_medicare(DFN, roi_on: "01/01/2026", name: "ZZCOV,TEST", number: CMS_EXAMPLE_MBI,
                              effective_on: "01/01/2026", client: client)

    refute result[:success]
    assert_equal :eligibility_failed, result[:error]
    assert_equal false, result[:rolled_back]
    refute client.received_calls.any? { |c| c[:rpc] == MEDICARE_RPC && c[:params][1] == "D" }
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

  def test_add_medicaid_rolls_back_record_when_eligibility_fails
    client = RecordingClient.new
    recorder = client
    client.define_singleton_method(:call_rpc_global_array) do |rpc, *params|
      recorder.received_calls << { rpc: rpc, params: params.map(&:to_s), context: recorder.current_context }
      case [ rpc, params[2].to_s, params[1].to_s ]
      when [ MEDICAID_RPC, Cov::MEDICAID_WINDOW, "A" ]
        MCD_HEADER + "1^^6^#{RS}#{US}"
      when [ MEDICAID_RPC, Cov::MEDICAID_ELIGIBILITY_WINDOW, "A" ]
        MCD_HEADER + "-1^Bad date.^^^#{RS}#{US}"
      when [ MEDICAID_RPC, Cov::MEDICAID_WINDOW, "D" ]
        MCD_HEADER + "1^^6^#{RS}#{US}"
      else
        ""
      end
    end
    RpmsRpc.configure { |c| c.client = client }

    result = Cov.add_medicaid(DFN, effective_on: "01/01/2026", coverage: "FULL", client: client)

    refute result[:success]
    assert_equal :eligibility_failed, result[:error]
    assert_equal true, result[:rolled_back]
    rollback = client.received_calls.find do |c|
      c[:rpc] == MEDICAID_RPC && c[:params][1] == "D" && c[:params][2] == Cov::MEDICAID_WINDOW && c[:params][3] == "6"
    end
    refute_nil rollback
  end

  private

  def ddr_gets_reply_key(file, iens, fields, flags)
    param = Ddr.gets_entry_param(file: file, iens: iens, fields: fields, flags: flags)
    [ "DDR GETS ENTRY DATA", param.to_s ].join("\0")
  end

  def ddr_lister_reply_key(**kwargs)
    [ "DDR LISTER", Ddr.lister_param(**kwargs).to_s ].join("\0")
  end

  def seed_medicare_absent!(client)
    key = ddr_gets_reply_key(MEDICARE_FILE, "#{DFN},", ".01", "I")
    client.instance_eval { @replies[key] = "[Errors]\n" }
  end

  def seed_medicare_present!(client)
    key = ddr_gets_reply_key(MEDICARE_FILE, "#{DFN},", ".01", "I")
    client.instance_eval do
      @replies[key] = "[Data]\n9000003^#{DFN}^.01^#{DFN}^#{DFN}\n"
    end
  end

  def seed_medicaid_owner!(client, record_ien:, patient_dfn:)
    key = ddr_gets_reply_key(MEDICAID_FILE, "#{record_ien},", ".01", "I")
    client.instance_eval do
      @replies[key] = "[Data]\n9000004^#{record_ien}^.01^#{patient_dfn}^#{patient_dfn}\n"
    end
  end

  def medicare_client_with_lister(lister_body)
    client = RecordingClient.new
    key = ddr_lister_reply_key(file: MEDICARE_ELIG_FILE, fields: "@;.01", flags: "IP", part: DFN.to_s)
    client.instance_eval { @replies[key] = lister_body }
    client
  end
end
