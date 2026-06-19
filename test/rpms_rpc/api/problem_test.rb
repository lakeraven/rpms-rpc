# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/version"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/problem"

class ProblemTest < Minitest::Test
  DFN = "8791"
  IEN = "5001"

  def teardown
    RpmsRpc.reset!
  end

  def test_add_returns_success_with_saved_ien
    RpmsRpc.mock! do |m|
      m.seed_scalar(:problem_edit, DFN, "5001")
    end

    result = RpmsRpc::Problem.add(DFN, { icd_code: "I10", description: "Hypertension" })
    assert result[:success]
    assert_equal 5001, result[:ien]
  end

  def test_add_dispatches_bgoprob1_edprob_with_action_marker
    RpmsRpc.mock! do |m|
      m.seed_scalar(:problem_edit, DFN, "5001")
    end

    RpmsRpc::Problem.add(DFN, { icd_code: "I10" })
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BGOPROB1 EDPROB" }
    refute_nil call
    assert_equal DFN, call[:params][0]
    assert_match(/\AA\^/, call[:params][1]) # action=A for add
  end

  def test_update_uses_edit_action_marker
    RpmsRpc.mock! do |m|
      m.seed_scalar(:problem_edit, DFN, "5001")
    end

    RpmsRpc::Problem.update(DFN, IEN, { description: "Updated" })
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BGOPROB1 EDPROB" }
    assert_match(/\AE\^/, call[:params][1]) # action=E for edit
  end

  def test_delete_uses_delete_action_marker_with_reason
    RpmsRpc.mock! do |m|
      m.seed_scalar(:problem_edit, DFN, "5001")
    end

    RpmsRpc::Problem.delete(DFN, IEN, reason: "Entered in error")
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BGOPROB1 EDPROB" }
    assert_match(/\AD\^/, call[:params][1])
    assert_includes call[:params][1], "Entered in error"
  end

  def test_filter_dispatches_class_rpc_with_scope_code
    RpmsRpc.mock! do |m|
      m.seed_keyed_collection(:problem_filter, DFN, [
        { ien: "1", description: "Diabetes", icd_code: "E11.9" }
      ])
    end

    rows = RpmsRpc::Problem.filter(DFN, scope: :core)
    assert_equal 1, rows.length

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BGOPROB GET CLASS" }
    assert_equal [ DFN, "C" ], call[:params]
  end

  def test_filter_maps_all_four_scope_symbols
    expected = { core: "C", episodic: "E", routine_admin: "R", inactive: "I" }
    expected.each do |scope, code|
      RpmsRpc.mock! do |m|
        m.seed_keyed_collection(:problem_filter, DFN, [])
      end
      RpmsRpc::Problem.filter(DFN, scope: scope)
      call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BGOPROB GET CLASS" }
      assert_equal code, call[:params][1], "scope #{scope} should map to #{code}"
    end
  end

  def test_filter_raises_on_unknown_scope
    assert_raises(ArgumentError) { RpmsRpc::Problem.filter(DFN, scope: :unknown) }
  end

  def test_blank_args_return_failure_shape
    assert_equal({ success: false, ien: nil, raw: nil }, RpmsRpc::Problem.add(nil, { x: 1 }))
    assert_equal({ success: false, ien: nil, raw: nil }, RpmsRpc::Problem.update("0", IEN, { x: 1 }))
    assert_equal({ success: false, ien: nil, raw: nil }, RpmsRpc::Problem.delete(DFN, nil, reason: "x"))
  end

  def test_add_raises_on_nil_problem_hash
    assert_raises(ArgumentError) { RpmsRpc::Problem.add(DFN, nil) }
  end

  def test_add_raises_on_non_hash_problem
    err = assert_raises(ArgumentError) { RpmsRpc::Problem.add(DFN, "not a hash") }
    assert_match(/must be a Hash/, err.message)
  end

  def test_payload_field_order_is_deterministic_regardless_of_hash_insertion_order
    RpmsRpc.mock! do |m|
      m.seed_scalar(:problem_edit, DFN, "5001")
    end
    RpmsRpc::Problem.add(DFN, { description: "Hypertension", icd_code: "I10", status: "active" })
    a = RpmsRpc.client.received_calls.last[:params][1]

    RpmsRpc.mock! do |m|
      m.seed_scalar(:problem_edit, DFN, "5001")
    end
    RpmsRpc::Problem.add(DFN, { icd_code: "I10", status: "active", description: "Hypertension" })
    b = RpmsRpc.client.received_calls.last[:params][1]

    assert_equal a, b, "payload must not depend on caller's Hash insertion order"
  end

  # ORQQPL stock-VistA surface (rr-txz)

  def test_lex_search_returns_matching_rows
    RpmsRpc.mock! do |m|
      m.seed_capability(:orqqpl_problem_workflow, supported: true)
      m.seed_keyed_collection(:problem_lex_search, "diab", [
        { code: "E11.9", description: "Type 2 diabetes mellitus" },
        { code: "E10.9", description: "Type 1 diabetes mellitus" }
      ])
    end

    rows = RpmsRpc::Problem.lex_search("diab")

    assert_equal 2, rows.length
    assert_equal "E11.9", rows.first[:code]
  end

  def test_lex_search_returns_empty_when_unsupported
    RpmsRpc.mock! do |m|
      m.seed_capability(:orqqpl_problem_workflow, supported: false)
    end

    assert_equal [], RpmsRpc::Problem.lex_search("anything")
  end

  def test_lex_search_returns_empty_for_blank_text
    RpmsRpc.mock! do |m|
      m.seed_capability(:orqqpl_problem_workflow, supported: true)
    end

    assert_equal [], RpmsRpc::Problem.lex_search("")
    assert_equal [], RpmsRpc::Problem.lex_search("   ")
  end

  def test_details_returns_row_for_ien
    RpmsRpc.mock! do |m|
      m.seed_capability(:orqqpl_problem_workflow, supported: true)
      m.seed_keyed_collection(:problem_detail, "5001", [
        { ien: "5001", status: "ACTIVE", description: "HTN" }
      ])
    end

    row = RpmsRpc::Problem.details("5001")

    refute_nil row
    assert_equal "5001", row[:ien]
    assert_equal "HTN", row[:description]
  end

  def test_details_returns_nil_when_unsupported
    RpmsRpc.mock! do |m|
      m.seed_capability(:orqqpl_problem_workflow, supported: false)
    end

    assert_nil RpmsRpc::Problem.details("5001")
  end

  def test_details_returns_nil_for_invalid_ien
    RpmsRpc.mock! do |m|
      m.seed_capability(:orqqpl_problem_workflow, supported: true)
    end

    assert_nil RpmsRpc::Problem.details(nil)
    assert_nil RpmsRpc::Problem.details("0")
  end

  def test_audit_history_dispatches_orqqpl_audit_hist
    RpmsRpc.mock! do |m|
      m.seed_capability(:orqqpl_problem_workflow, supported: true)
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
      m.seed_capability(:orqqpl_problem_workflow, supported: true)
      m.seed_keyed_collection(:problem_comments, "5001", [
        { comment: "follow-up needed" }
      ])
    end

    rows = RpmsRpc::Problem.comments("5001")

    assert_equal 1, rows.length
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORQQPL PROB COMMENTS" }
    refute_nil call
  end

  def test_inactivate_success_via_orqqpl_inactivate
    RpmsRpc.mock! do |m|
      m.seed_capability(:orqqpl_problem_workflow, supported: true)
      m.seed_scalar(:problem_inactivate, "5001", "1^INACTIVATED")
    end

    result = RpmsRpc::Problem.inactivate("5001")

    assert result[:success]
    assert_equal "INACTIVATED", result[:message]
  end

  def test_inactivate_bare_ien_response_preserves_value
    # Defensive: an ORQQPL RPC that returns a bare IEN like "10" must
    # not be parsed as `message: "0"` (mirrors PR #157 BMC fix).
    RpmsRpc.mock! do |m|
      m.seed_capability(:orqqpl_problem_workflow, supported: true)
      m.seed_scalar(:problem_inactivate, "5001", "10")
    end

    result = RpmsRpc::Problem.inactivate("5001")

    assert result[:success]
    assert_equal "10", result[:message]
  end

  def test_inactivate_zero_response_yields_failure
    RpmsRpc.mock! do |m|
      m.seed_capability(:orqqpl_problem_workflow, supported: true)
      m.seed_scalar(:problem_inactivate, "5001", "0^problem still active")
    end

    result = RpmsRpc::Problem.inactivate("5001")

    refute result[:success]
    assert_equal "problem still active", result[:message]
  end

  def test_inactivate_short_circuits_when_unsupported
    RpmsRpc.mock! do |m|
      m.seed_capability(:orqqpl_problem_workflow, supported: false)
    end

    result = RpmsRpc::Problem.inactivate("5001")

    refute result[:success]
    assert_match(/not available/, result[:error])
  end

  def test_verify_dispatches_orqqpl_verify
    RpmsRpc.mock! do |m|
      m.seed_capability(:orqqpl_problem_workflow, supported: true)
      m.seed_scalar(:problem_verify, "5001", "1")
    end

    result = RpmsRpc::Problem.verify("5001")

    assert result[:success]
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORQQPL VERIFY" }
    refute_nil call
  end

  def test_zero_or_blank_save_response_yields_failure
    RpmsRpc.mock! do |m|
      m.seed_scalar(:problem_edit, DFN, "0")
    end
    result = RpmsRpc::Problem.add(DFN, { icd_code: "X" })
    refute result[:success]
  end
end
