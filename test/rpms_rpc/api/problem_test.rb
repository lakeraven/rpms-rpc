# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/problem"

class ProblemTest < Minitest::Test
  DFN = "8791"
  IEN = "5001"

  def teardown
    RpmsRpc.reset!
  end

  # RETIRED — Problem.filter and the :problem_filter mapping are gone.
  #
  # The #8994 registry binds "BGOPROB GET CLASS" to DICLASS^BGOASLK
  # (.broker_dumps_8994_20260607.txt:3103 "BGOPROB GET CLASS^DICLASS^
  # BGOASLK^2"), which is "Get the classifications for an asthma DX"
  # (BGOASLK.m:52-67). It takes ONE param — "ICD ^ SNOMED ^ class type"
  # (BGOASLK.m:53) — returns "" unless $$CHECK^BGOASLK says the dx is
  # asthma (BGOASLK.m:58-60), and emits TWO-piece rows read out of
  # ^APCDPLCL (BGOASLK.m:65: $P(CTYPE,U,1)_"^"_$P(CTYPE,U,2)).
  #
  # It is not a problem list, it is not scoped by patient, and it never
  # took a DFN. The old wrapper sent (DFN, scope_code) and declared a
  # ten-piece ORQQPL problem-list row over the reply; its "IPL scope
  # classes" C/E/R/I appear nowhere in the routine. Same invented-capability
  # class as the retired BHDPTRPC family (#174/#184).
  def test_problem_filter_mapping_is_not_registered
    refute_respond_to RpmsRpc::DataMapper, :problem_filter,
      "an asthma-classification RPC must not be registered as a problem-list filter"
  end

  # Nothing else may quietly re-bind the name to the old shape either.
  def test_no_mapping_claims_bgoprob_get_class
    registry = RpmsRpc::DataMapper.instance_variable_get(:@registry)
    claimed = registry.values.select { |m| m.rpc_name == "BGOPROB GET CLASS" }

    assert_empty claimed,
      "BGOPROB GET CLASS is DICLASS^BGOASLK — bind it deliberately or not at all"
  end

  def test_problem_no_longer_exposes_the_fabricated_scope_filter
    refute_respond_to RpmsRpc::Problem, :filter
    refute RpmsRpc::Problem.const_defined?(:SCOPE_CODES, false),
      "the invented IPL scope codes are gone with the method"
  end

  # ORQQPL stock-VistA surface (rr-txz)

  def test_lex_search_returns_matching_rows
    RpmsRpc.mock! do |m|
      m.seed_keyed_collection(:problem_lex_search, "diab", [
        { code: "E11.9", description: "Type 2 diabetes mellitus" },
        { code: "E10.9", description: "Type 1 diabetes mellitus" }
      ])
    end

    rows = RpmsRpc::Problem.lex_search("diab")

    assert_equal 2, rows.length
    assert_equal "E11.9", rows.first[:code]
  end

  def test_lex_search_returns_empty_for_blank_text
    RpmsRpc.mock! do |m|
    end

    assert_equal [], RpmsRpc::Problem.lex_search("")
    assert_equal [], RpmsRpc::Problem.lex_search("   ")
  end

  # DETAIL(Y,DFN,PROBIEN,ID) (ORQQPL.m:21): the patient comes first, so the
  # mock keys the reply by DFN (#259).
  def test_details_returns_row_for_ien
    RpmsRpc.mock! do |m|
      m.seed_keyed_collection(:problem_detail, DFN, [
        { ien: "5001", status: "ACTIVE", description: "HTN" }
      ])
    end

    row = RpmsRpc::Problem.details(DFN, "5001")

    refute_nil row
    assert_equal "5001", row[:ien]
    assert_equal "HTN", row[:description]
  end

  def test_details_returns_nil_for_invalid_ien
    RpmsRpc.mock! do |m|
    end

    assert_nil RpmsRpc::Problem.details(DFN, nil)
    assert_nil RpmsRpc::Problem.details(DFN, "0")
    assert_nil RpmsRpc::Problem.details(nil, "5001")
    assert_nil RpmsRpc::Problem.details("0", "5001")
  end

  def test_audit_history_dispatches_orqqpl_audit_hist
    RpmsRpc.mock! do |m|
      m.seed_keyed_collection(:problem_audit_history, "5001", [
        { event: "ADDED", date: "20260615" }
      ])
    end

    rows = RpmsRpc::Problem.audit_history("5001")

    assert_equal 1, rows.length
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORQQPL AUDIT HIST" }
    refute_nil call
    assert_equal [ "5001" ], call[:params]
  end

  def test_comments_dispatches_orqqpl_prob_comments
    RpmsRpc.mock! do |m|
      m.seed_keyed_collection(:problem_comments, "5001", [
        { comment: "follow-up needed" }
      ])
    end

    rows = RpmsRpc::Problem.comments("5001")

    assert_equal 1, rows.length
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORQQPL PROB COMMENTS" }
    refute_nil call
  end

  def test_problem_list_mock_round_trip_active_icd_keeps_icd_code
    RpmsRpc.mock! do |m|
      m.seed(:problem_list, DFN,
             { ien: "10", description: "Hypertension", status: "A", icd_code: "I10", inactive_icd: false })
    end

    row = RpmsRpc::Problem.for_patient(DFN).first
    refute_nil row
    refute row[:inactive_icd]
    assert_equal "I10", row[:icd_code]
  end
end
