# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/problem"
require_relative "../captured_replies"

# Problem.duplicate_check (BGOPROB2 DUPCHK, DUPCHK^BGOPROB2) and a lateralized
# Problem.add (BGOPROB SET, P-line piece 13). The replies are the build's
# (test/fixtures/captured_replies/problem-duplicate-check.yml): each flow run
# as PROFILE,MD on a throwaway container, recorded and replayed through
# CiaClient. Filing and reading back are proven live
# (test/live/problem_duplicate_check_live_test.rb).
class ProblemDuplicateCheckTest < Minitest::Test
  SLUG = "problem-duplicate-check"
  DFN = 990_023
  OTITIS = {
    snomed_ct: "65363002", descriptive_ct: "804858018", icd_code: "H66.90",
    description: "Otitis media", location_ien: "7819", laterality: "Left"
  }.freeze

  def teardown
    RpmsRpc.reset!
  end

  def replay_flow(name)
    client = CapturedReplies::ReplayCiaClient.new(CapturedReplies.flow_script(SLUG, name))
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def sent(client) = client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params] ] }

  def test_a_concept_not_on_the_list_answers_its_new_entry_for_the_laterality_sent
    client = replay_flow("check_new_left")

    result = RpmsRpc::Problem.duplicate_check(DFN, "65363002", laterality: "left")

    assert_equal CapturedReplies.flow_calls(SLUG, "check_new_left"), sent(client)
    assert_equal [ "BGOPROB2 DUPCHK", [ "990023^65363002^272741003|7771000^" ] ], sent(client).first,
                 "DFN ^ SNOMED CT ^ laterality ^ problem IEN (BGOPROB2.m:94-99)"
    assert_empty result[:on_file]
    entry = result[:new_entry]
    assert_equal 0, entry[:ien]
    assert_equal [ "804858018", "Otitis media", [ "H66.90" ], "272741003|7771000", "Laterality|Left" ],
                 entry.values_at(:description_id, :narrative, :icd_codes, :laterality, :laterality_text)
    assert entry[:prompts_laterality], "BSTS prompts laterality for otitis media"
    assert entry[:lateralized]
    assert entry[:exact]
    assert_nil entry[:status], "a new entry has no status on file"
  end

  def test_a_lateralized_add_sends_the_laterality_pair_in_piece_13
    client = replay_flow("add_left")

    result = RpmsRpc::Problem.add(DFN, OTITIS)

    assert_equal({ success: true, ien: 148, raw: "148" }, result)
    assert_equal CapturedReplies.flow_calls(SLUG, "add_left"), sent(client)
    set = client.calls.find { |c| c[:rpc] == "BGOPROB SET" }
    assert_equal [ "P^65363002^804858018^Otitis media^H66.90^7819^^^^^^^272741003|7771000" ], set[:params][3],
                 "piece 12 (inpatient diagnosis) empty, piece 13 the laterality attribute|qualifier (BGOPROB3.m:128)"
  end

  def test_the_problem_on_file_is_answered_for_its_laterality
    replay_flow("check_on_file_left")

    result = RpmsRpc::Problem.duplicate_check(DFN, "65363002", laterality: "Left")

    assert_nil result[:new_entry], "the build answers no new entry when the concept is on file"
    assert_equal 1, result[:on_file].size, result[:on_file].inspect
    problem = result[:on_file].first
    assert_equal [ 148, "65363002", "272741003|7771000", "E", [ "H66.90" ] ],
                 problem.values_at(:ien, :snomed_ct, :laterality, :status, :icd_codes)
    assert_match(/\AOtitis media/, problem[:narrative])
  end

  def test_another_laterality_is_not_the_problem_on_file
    replay_flow("check_right")

    result = RpmsRpc::Problem.duplicate_check(DFN, "65363002", laterality: "Right")

    assert_empty result[:on_file]
    assert_equal "272741003|24028007", result[:new_entry][:laterality]
  end

  def test_no_laterality_answers_the_lateralized_problem_and_a_new_entry
    replay_flow("check_unlateralized")

    result = RpmsRpc::Problem.duplicate_check(DFN, "65363002")

    assert_equal [ 148 ], result[:on_file].map { |e| e[:ien] }
    refute result[:on_file].first[:exact], "the left problem is an equivalent, not an exact, match"
    assert_nil result[:new_entry][:laterality]
  end

  def test_a_deleted_problem_is_not_on_file
    replay_flow("check_after_delete")

    result = RpmsRpc::Problem.duplicate_check(DFN, "65363002", laterality: "Left")

    assert_empty result[:on_file]
    assert_equal 0, result[:new_entry][:ien]
  end

  def test_a_concept_bsts_maps_to_two_codes_answers_both
    replay_flow("check_two_maps")

    result = RpmsRpc::Problem.duplicate_check(DFN, "421986006")

    assert_equal [ "E11.29", "R80.1" ], result[:new_entry][:icd_codes]
  end

  def test_input_the_check_cannot_take_is_refused_before_the_wire
    client = replay_flow("check_new_left")

    assert_raises(ArgumentError) { RpmsRpc::Problem.duplicate_check(0, "65363002") }
    assert_raises(ArgumentError) { RpmsRpc::Problem.duplicate_check(DFN, "6536^3002") }
    assert_raises(ArgumentError) { RpmsRpc::Problem.duplicate_check(DFN, "") }
    error = assert_raises(ArgumentError) { RpmsRpc::Problem.duplicate_check(DFN, "65363002", laterality: "Up") }
    assert_includes error.message, "Left, Right, Bilateral"
    assert_empty sent(client)
  end

  def test_a_laterality_add_does_not_take_is_refused_before_the_wire
    client = replay_flow("add_left")

    result = RpmsRpc::Problem.add(DFN, OTITIS.merge(laterality: "272741003|7771000"))

    refute result[:success]
    assert_includes result[:error], "Left, Right, Bilateral"
    assert_empty sent(client)
  end
end
