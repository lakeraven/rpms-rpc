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
# Panel round 2 (pinned AGGUPMCR.m / AGGUPMCD.m): medicare_update / medicaid_update
# are module-internal (not public, no HTTP shape); public writers only; PARMS
# allowlists exclude RIEN/MIEN and refuse "=", OVERRIDE, "^", and controls;
# guard DDR reads use the same client: as the write; verification_failed on
# guard failures; #9000003.11 lister IENS ",DFN," only; add_medicare never
# deletes a header on rollback; delete_medicare* refuse :no_medicare without header.
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

  # -- public API (rpms-rpc#382) ---------------------------------------------

  PUBLIC_METHODS = %i[
    for_patient add_medicare delete_medicare delete_medicare_record add_medicaid delete_medicaid
  ].freeze

  def test_public_coverage_api_surface
    PUBLIC_METHODS.each { |name| assert_respond_to Cov, name, "rpms-rpc#382" }
    refute_respond_to Cov, :medicare_update
    refute_respond_to Cov, :medicaid_update
  end

  def test_low_level_medicare_and_medicaid_writers_are_not_callable
    assert_raises(NoMethodError) do
      Cov.medicare_update(DFN, proc: "A", definition: Cov::MEDICARE_WINDOW)
    end
    assert_raises(NoMethodError) do
      Cov.medicaid_update(DFN, proc: "A", definition: Cov::MEDICAID_WINDOW)
    end
  end

  def test_window_field_allowlists_exclude_rien_and_mien
    [ MEDICARE_HEADER_FIELDS, MEDICARE_ELIGIBILITY_FIELDS,
      MEDICAID_HEADER_FIELDS, MEDICAID_ELIGIBILITY_FIELDS ].each do |names|
      names.each do |name|
        refute_includes %w[RIEN MIEN], name.upcase, "IEN keys must not be PARMS allowlist entries"
      end
    end
  end

  # -- add_medicare AGG wire (UPD^AGGUPMCR.m:7) ------------------------------

  def test_add_medicare_sends_dfn_proc_def_mien_parms_under_aggrpc
    client = RecordingClient.new
    recorder = client
    client.define_singleton_method(:call_rpc_global_array) do |rpc, *params|
      recorder.received_calls << { rpc: rpc, params: params.map(&:to_s), context: recorder.current_context }
      MCR_HEADER + "1^^#{DFN}^#{RS}#{US}"
    end
    seed_medicare_absent!(client)
    RpmsRpc.configure { |c| c.client = client }

    Cov.add_medicare(DFN, roi_on: "01/01/2026", name: "ZZCOV,TEST", number: CMS_EXAMPLE_MBI,
                     effective_on: "01/01/2026", client: client)

    header = client.received_calls.find { |c| c[:params][2] == Cov::MEDICARE_WINDOW }
    refute_nil header
    assert_equal MEDICARE_RPC, header[:rpc]
    assert_equal [ DFN.to_s, "A", Cov::MEDICARE_WINDOW, "", "AGGMCROI=01/01/2026#{FS}AGGMCNME=ZZCOV,TEST#{FS}AGGMCNUM=#{CMS_EXAMPLE_MBI}" ],
                 header[:params]
    assert_equal Agg::CONTEXT, header[:context]
  end

  def test_add_medicare_only_uses_medicare_and_medicare_eligibility_windows
    client = RecordingClient.new
    recorder = client
    client.define_singleton_method(:call_rpc_global_array) do |rpc, *params|
      recorder.received_calls << { rpc: rpc, params: params.map(&:to_s), context: recorder.current_context }
      case params[2].to_s
      when Cov::MEDICARE_WINDOW
        MCR_HEADER + "1^^#{DFN}^#{RS}#{US}"
      when Cov::MEDICARE_ELIGIBILITY_WINDOW
        MCR_HEADER + "1^^#{DFN}^1#{RS}#{US}"
      else
        flunk "unexpected AGG definition #{params[2].inspect}"
      end
    end
    seed_medicare_absent!(client)
    RpmsRpc.configure { |c| c.client = client }

    Cov.add_medicare(DFN, roi_on: "01/01/2026", name: "ZZCOV,TEST", number: CMS_EXAMPLE_MBI,
                     effective_on: "01/01/2026", client: client)

    defs = client.received_calls.select { |c| c[:rpc] == MEDICARE_RPC }.map { |c| c[:params][2] }
    assert_equal [ Cov::MEDICARE_WINDOW, Cov::MEDICARE_ELIGIBILITY_WINDOW ], defs
  end

  def test_add_medicare_rejects_caret_in_field_values
    client = RecordingClient.new
    RpmsRpc.configure { |c| c.client = client }

    assert_raises(ArgumentError) do
      Cov.add_medicare(DFN, roi_on: "01/01/2026", name: "BAD^NAME", number: CMS_EXAMPLE_MBI,
                       effective_on: "01/01/2026", client: client)
    end
    assert_empty client.received_calls
  end

  def test_add_medicare_rejects_equals_in_field_values
    client = RecordingClient.new
    RpmsRpc.configure { |c| c.client = client }

    assert_raises(ArgumentError) do
      Cov.add_medicare(DFN, roi_on: "01/01/2026", name: "ZZCOV,TEST", number: "MBI=1",
                       effective_on: "01/01/2026", client: client)
    end
    assert_empty client.received_calls
  end

  def test_add_medicare_rejects_control_character_in_field_values
    client = RecordingClient.new
    RpmsRpc.configure { |c| c.client = client }

    assert_raises(ArgumentError) do
      Cov.add_medicare(DFN, roi_on: "01/01/2026", name: "ZZ\x1fCOV", number: CMS_EXAMPLE_MBI,
                       effective_on: "01/01/2026", client: client)
    end
    assert_empty client.received_calls
  end

  def test_add_medicare_restores_context_when_rpc_raises
    client = RecordingClient.new
    client.create_context("OR CPRS GUI CHART")
    RpmsRpc.configure { |c| c.client = client }

    def client.call_rpc_global_array(*)
      raise RpmsRpc::Client::RpcError, "boom"
    end

    assert_raises(RpmsRpc::Client::RpcError) do
      Cov.add_medicare(DFN, roi_on: "01/01/2026", name: "ZZCOV,TEST", number: CMS_EXAMPLE_MBI,
                       effective_on: "01/01/2026", client: client)
    end
    assert_equal "OR CPRS GUI CHART", client.current_context
  end

  # -- add_medicaid AGG wire (UPD^AGGUPMCD.m:5) ------------------------------

  def test_add_medicaid_sends_dfn_proc_def_rien_mien_parms
    client = RecordingClient.new
    recorder = client
    client.define_singleton_method(:call_rpc_global_array) do |rpc, *params|
      recorder.received_calls << { rpc: rpc, params: params.map(&:to_s), context: recorder.current_context }
      if rpc == MEDICAID_RPC && params[2].to_s == Cov::MEDICAID_WINDOW
        MCD_HEADER + "1^^9^#{RS}#{US}"
      else
        MCD_HEADER + "1^^9^3261031#{RS}#{US}"
      end
    end
    RpmsRpc.configure { |c| c.client = client }

    Cov.add_medicaid(DFN, effective_on: "01/01/2026", coverage: "FULL", client: client)

    elig = client.received_calls.find { |c| c[:params][2] == Cov::MEDICAID_ELIGIBILITY_WINDOW }
    refute_nil elig
    assert_equal [ DFN.to_s, "A", Cov::MEDICAID_ELIGIBILITY_WINDOW, "9", "",
                  "AGGMDESD=01/01/2026#{FS}AGGMDECV=FULL" ], elig[:params]
    assert_equal Agg::CONTEXT, elig[:context]
  end

  def test_add_medicaid_only_uses_medicaid_and_medicaid_eligibility_windows
    client = RecordingClient.new
    recorder = client
    client.define_singleton_method(:call_rpc_global_array) do |rpc, *params|
      recorder.received_calls << { rpc: rpc, params: params.map(&:to_s), context: recorder.current_context }
      if params[2].to_s == Cov::MEDICAID_WINDOW
        MCD_HEADER + "1^^6^#{RS}#{US}"
      else
        MCD_HEADER + "1^^6^3261031#{RS}#{US}"
      end
    end
    RpmsRpc.configure { |c| c.client = client }

    Cov.add_medicaid(DFN, effective_on: "01/01/2026", coverage: "FULL", client: client)

    defs = client.received_calls.select { |c| c[:rpc] == MEDICAID_RPC }.map { |c| c[:params][2] }
    assert_equal [ Cov::MEDICAID_WINDOW, Cov::MEDICAID_ELIGIBILITY_WINDOW ], defs
  end

  def test_add_medicaid_override_in_coverage_makes_no_call
    client = RecordingClient.new
    RpmsRpc.configure { |c| c.client = client }

    assert_raises(ArgumentError) do
      Cov.add_medicaid(DFN, effective_on: "01/01/2026", coverage: "OVERRIDE=Y", client: client)
    end
    assert_empty client.received_calls
  end

  def test_add_medicaid_rejects_override_case_insensitive_in_coverage
    client = RecordingClient.new
    RpmsRpc.configure { |c| c.client = client }

    assert_raises(ArgumentError) do
      Cov.add_medicaid(DFN, effective_on: "01/01/2026", coverage: "full override", client: client)
    end
    assert_empty client.received_calls
  end

  def test_add_medicaid_rejects_equals_in_coverage_value
    client = RecordingClient.new
    RpmsRpc.configure { |c| c.client = client }

    assert_raises(ArgumentError) do
      Cov.add_medicaid(DFN, effective_on: "01/01/2026", coverage: "FULL=Y", client: client)
    end
    assert_empty client.received_calls
  end

  def test_add_medicaid_restores_context_when_rpc_raises
    client = RecordingClient.new
    client.create_context("OR CPRS GUI CHART")
    RpmsRpc.configure { |c| c.client = client }

    def client.call_rpc_global_array(*)
      raise RpmsRpc::Client::RpcError, "boom"
    end

    assert_raises(RpmsRpc::Client::RpcError) do
      Cov.add_medicaid(DFN, effective_on: "01/01/2026", coverage: "FULL", client: client)
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
    seed_medicare_present!(client)
    RpmsRpc.configure { |c| c.client = client }

    Cov.delete_medicare(DFN, eligibility_mien: "3", client: client)

    agg = client.received_calls.select { |c| c[:rpc] == MEDICARE_RPC }
    assert_equal 1, agg.size
    assert_equal [ DFN.to_s, "D", Cov::MEDICARE_ELIGIBILITY_WINDOW, "3", "" ], agg.first[:params]
  end

  def test_delete_medicare_refuses_without_medicare_header
    client = RecordingClient.new
    seed_medicare_absent!(client)
    RpmsRpc.configure { |c| c.client = client }

    result = Cov.delete_medicare(DFN, eligibility_mien: "3", client: client)

    refute_nil result, "delete_medicare must answer with a result hash when no Medicare header"
    refute result[:success]
    assert_equal :no_medicare, result[:error]
    assert_empty client.received_calls.select { |c| c[:rpc] == MEDICARE_RPC }
  end

  def test_delete_medicare_guard_reads_use_passed_client_not_rpms_default
    default = RecordingClient.new
    write_client = RecordingClient.new(MEDICARE_RPC => MCR_HEADER + "1^^#{DFN}^#{RS}#{US}")
    seed_medicare_present!(write_client)
    RpmsRpc.configure { |c| c.client = default }

    Cov.delete_medicare(DFN, eligibility_mien: "3", client: write_client)

    assert write_client.received_calls.any? { |c| c[:rpc] == "DDR GETS ENTRY DATA" }
    refute default.received_calls.any? { |c| c[:rpc] == "DDR GETS ENTRY DATA" }
  end

  # -- delete_medicare_record: header only when #9000003.11 is empty --------

  def test_delete_medicare_record_refuses_when_eligibility_rows_remain
    client = medicare_client_with_lister("[Data]\n1^row\n")
    RpmsRpc.configure { |c| c.client = client }
    seed_medicare_present!(client)

    result = Cov.delete_medicare_record(DFN, client: client)

    refute result[:success]
    assert_equal :verification_failed, result[:error]
    assert_empty client.received_calls.select { |c| c[:rpc] == MEDICARE_RPC }
  end

  def test_delete_medicare_record_fails_closed_when_eligibility_lister_errors
    client = medicare_client_with_lister("[Errors]\n")
    seed_medicare_present!(client)
    RpmsRpc.configure { |c| c.client = client }

    result = Cov.delete_medicare_record(DFN, client: client)

    refute result[:success]
    assert_equal :verification_failed, result[:error]
    assert_empty client.received_calls.select { |c| c[:rpc] == MEDICARE_RPC }
  end

  def test_delete_medicare_record_refuses_without_medicare_header
    client = medicare_client_with_lister("[Data]\n")
    seed_medicare_absent!(client)
    RpmsRpc.configure { |c| c.client = client }

    result = Cov.delete_medicare_record(DFN, client: client)

    refute_nil result, "delete_medicare_record must answer with a result hash when no Medicare header"
    refute result[:success]
    assert_equal :no_medicare, result[:error]
    assert_empty client.received_calls.select { |c| c[:rpc] == MEDICARE_RPC }
  end

  def test_delete_medicare_record_deletes_header_when_no_eligibility_rows
    client = medicare_client_with_lister("[Data]\n")
    seed_medicare_present!(client)
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
    assert_includes lister[:params].join, ",#{DFN},"
    refute_includes lister[:params].join, "PART"
    header_del = client.received_calls.find { |c| c[:rpc] == MEDICARE_RPC }
    assert_equal [ DFN.to_s, "D", Cov::MEDICARE_WINDOW, "", "" ], header_del[:params]
  end

  def test_delete_medicare_record_guard_reads_use_passed_client_not_rpms_default
    default = RecordingClient.new
    write_client = medicare_client_with_lister("[Data]\n")
    seed_medicare_present!(write_client)
    write_client.define_singleton_method(:call_rpc_global_array) do |rpc, *params|
      write_client.received_calls << { rpc: rpc, params: params.map(&:to_s), context: write_client.current_context }
      MCR_HEADER + "1^^#{DFN}^#{RS}#{US}" if rpc == MEDICARE_RPC
    end
    RpmsRpc.configure { |c| c.client = default }

    Cov.delete_medicare_record(DFN, client: write_client)

    assert write_client.received_calls.any? { |c| c[:rpc] == "DDR LISTER" }
    refute default.received_calls.any? { |c| c[:rpc] == "DDR LISTER" }
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
    assert_equal :verification_failed, result[:error]
    assert_empty client.received_calls.select { |c| c[:rpc] == MEDICAID_RPC }
  end

  def test_delete_medicaid_fails_closed_when_ownership_read_errors
    client = RecordingClient.new
    key = ddr_gets_reply_key(MEDICAID_FILE, "6,", ".01", "I")
    client.instance_eval { @replies[key] = "[Errors]\n" }
    RpmsRpc.configure { |c| c.client = client }

    result = Cov.delete_medicaid(DFN, record_ien: "6", eligibility_mien: "1", client: client)

    refute result[:success]
    assert_equal :verification_failed, result[:error]
    assert_empty client.received_calls.select { |c| c[:rpc] == MEDICAID_RPC }
  end

  def test_delete_medicaid_guard_reads_use_passed_client_not_rpms_default
    default = RecordingClient.new
    write_client = RecordingClient.new(MEDICAID_RPC => MCD_HEADER + "1^^6^99#{RS}#{US}")
    seed_medicaid_owner!(write_client, record_ien: "6", patient_dfn: DFN)
    RpmsRpc.configure { |c| c.client = default }

    Cov.delete_medicaid(DFN, record_ien: "6", eligibility_mien: "99", client: write_client)

    assert write_client.received_calls.any? { |c| c[:rpc] == "DDR GETS ENTRY DATA" }
    refute default.received_calls.any? { |c| c[:rpc] == "DDR GETS ENTRY DATA" }
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

  def test_add_medicare_never_deletes_header_when_eligibility_fails
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
    seed_medicare_absent!(client)
    RpmsRpc.configure { |c| c.client = client }

    result = Cov.add_medicare(DFN, roi_on: "01/01/2026", name: "ZZCOV,TEST", number: CMS_EXAMPLE_MBI,
                              effective_on: "01/01/2026", client: client)

    refute result[:success]
    assert_equal :eligibility_failed, result[:error]
    assert_equal false, result[:rolled_back]
    assert_equal true, result[:header_left]
    refute client.received_calls.any? { |c| c[:rpc] == MEDICARE_RPC && c[:params][1] == "D" }
  end

  def test_add_medicare_leaves_header_when_eligibility_fails_and_header_preexisted
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
    assert_equal true, result[:header_left]
    refute client.received_calls.any? { |c| c[:rpc] == MEDICARE_RPC && c[:params][1] == "D" }
  end

  def test_add_medicaid_returns_record_ien_missing_when_header_has_no_record_ien
    client = RecordingClient.new(MEDICAID_RPC => MCD_HEADER + "1^^^#{RS}#{US}")
    RpmsRpc.configure { |c| c.client = client }

    result = Cov.add_medicaid(DFN, effective_on: "01/01/2026", coverage: "FULL", client: client)

    refute result[:success]
    assert_equal :record_ien_missing, result[:error]
    assert_equal 1, client.received_calls.count { |c| c[:rpc] == MEDICAID_RPC }
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
    key = ddr_lister_reply_key(file: MEDICARE_ELIG_FILE, fields: "@;.01", flags: "IP", iens: ",#{DFN},")
    client.instance_eval { @replies[key] = lister_body }
    client
  end
end
