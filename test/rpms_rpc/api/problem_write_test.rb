# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/problem"
require_relative "../captured_replies"

# Problem.add / .update / .delete: BGOPROB SET (SET^BGOPROB -> PROB^BGOPROB3)
# and BGOPROB DEL (DEL^BGOPROB3), the IHS problem-list writes (rpms-rpc#527).
# The replies are the build's (test/fixtures/captured_replies/problem-write.yml):
# each write run as PROFILE,MD on a throwaway container, recorded as a flow
# and replayed through CiaClient. Each write reads the problem with DDR GETS:
# update and delete first, to check it is the patient's, and every write
# after, to check what was filed.
class ProblemWriteTest < Minitest::Test
  SLUG = "problem-write"
  DFN = 990_055
  OTHER_DFN = 990_056
  IEN = 148
  DEPRESSION = {
    icd_code: "F32.9", description: "SYNTH CAPTURE DEPRESSION", location_ien: "7819",
    status: "Chronic", onset_date: "11/01/2026"
  }.freeze

  def teardown
    RpmsRpc.reset!
  end

  def replay(script)
    client = CapturedReplies::ReplayCiaClient.new(script)
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def replay_flow(name) = replay(CapturedReplies.flow_script(SLUG, name))

  def sent(client) = client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params] ] }

  def reply(name) = CapturedReplies.raw(SLUG, name)

  # --- add -----------------------------------------------------------------

  def test_add_files_the_problem_and_reads_it_back
    client = replay_flow("add_new")

    result = RpmsRpc::Problem.add(DFN, DEPRESSION)

    assert_equal({ success: true, ien: IEN, raw: "148" }, result)
    assert_equal CapturedReplies.flow_calls(SLUG, "add_new"), sent(client)
    set = client.calls.find { |c| c[:rpc] == "BGOPROB SET" }
    assert_equal [ DFN.to_s, "", "", [ "P^^^SYNTH CAPTURE DEPRESSION^F32.9^7819^11/01/2026^Chronic^^^" ], "1" ], set[:params],
                 "DFN, PRIEN empty for a new problem, VIEN, the P line, SPEC=1 (BGOPROB.m:242)"
  end

  def test_add_whose_icd_the_build_cannot_resolve_is_not_filed
    replay_flow("add_unresolved_icd")

    result = RpmsRpc::Problem.add(DFN, DEPRESSION.merge(icd_code: "NOTACODE"))

    refute result[:success], "the build filed problem 149 with .01 = -1; that is not a problem on the list"
    assert_equal :not_filed, result[:error]
    assert_equal 149, result[:ien], "the IEN the build gave is reported, so the caller can find the entry"
  end

  def test_add_without_a_location_is_the_builds_refusal
    client = replay_flow("add_no_location")

    result = RpmsRpc::Problem.add(DFN, DEPRESSION.merge(location_ien: nil))

    assert_equal({ success: false, ien: nil, raw: "-1049^The specified location is unknown." }, result)
    assert_equal [ "BGOPROB SET" ], sent(client).map(&:first), "a refusal is not read back"
  end

  def test_add_for_a_patient_not_on_file_is_the_builds_refusal
    replay_flow("add_unknown_patient")

    result = RpmsRpc::Problem.add(1_999_999, DEPRESSION)

    assert_equal({ success: false, ien: nil, raw: "-1001^Unknown patient specified" }, result)
  end

  def test_add_reply_naming_another_patient_on_read_back_is_not_filed
    # The add_new SET reply, then the read-back of a problem on file for DFN
    # 990055, sent as if for DFN 990056: the read-back must name the patient.
    replay("BGOPROB SET" => [ reply("add_new/1") ], "DDR GETS ENTRY DATA" => [ reply("add_new/2") ])

    result = RpmsRpc::Problem.add(OTHER_DFN, DEPRESSION)

    refute result[:success]
    assert_equal :not_filed, result[:error]
  end

  def test_add_p_line_does_not_depend_on_hash_order
    client = replay_flow("add_new")
    RpmsRpc::Problem.add(DFN, DEPRESSION.to_a.reverse.to_h)

    assert_equal CapturedReplies.flow_calls(SLUG, "add_new"), sent(client)
  end

  # --- update --------------------------------------------------------------

  def test_update_checks_the_patient_then_files_and_reads_back
    client = replay_flow("update")

    result = RpmsRpc::Problem.update(DFN, IEN, DEPRESSION.merge(status: "Inactive", description: "SYNTH CAPTURE EDITED"))

    assert_equal({ success: true, ien: IEN, raw: "148" }, result)
    assert_equal CapturedReplies.flow_calls(SLUG, "update"), sent(client)
    assert_equal [ "DDR GETS ENTRY DATA", "BGOPROB SET", "DDR GETS ENTRY DATA" ], sent(client).map(&:first)
    assert_equal IEN.to_s, client.calls.find { |c| c[:rpc] == "BGOPROB SET" }[:params][1], "PRIEN carries the problem on an edit"
  end

  def test_update_of_another_patients_problem_sends_no_write
    client = replay_flow("update_wrong_patient")

    result = RpmsRpc::Problem.update(OTHER_DFN, IEN, DEPRESSION)

    assert_equal({ success: false, ien: nil, raw: nil, error: :wrong_patient }, result)
    assert_equal [ "DDR GETS ENTRY DATA" ], sent(client).map(&:first)
  end

  # --- delete --------------------------------------------------------------

  def test_delete_checks_the_patient_then_deletes_and_reads_back
    client = replay_flow("delete")

    result = RpmsRpc::Problem.delete(DFN, IEN, reason: "Entered in error")

    assert_equal({ success: true, ien: IEN, raw: [] }, result)
    assert_equal CapturedReplies.flow_calls(SLUG, "delete"), sent(client)
    assert_equal [ "148^^Entered in error" ], client.calls.find { |c| c[:rpc] == "BGOPROB DEL" }[:params],
                 "IEN ^ TYPE ^ REASON (DEL^BGOPROB3)"
  end

  def test_delete_of_another_patients_problem_sends_no_write
    client = replay_flow("delete_wrong_patient")

    result = RpmsRpc::Problem.delete(OTHER_DFN, IEN, reason: "Entered in error")

    assert_equal({ success: false, ien: nil, raw: nil, error: :wrong_patient }, result)
    assert_equal [ "DDR GETS ENTRY DATA" ], sent(client).map(&:first)
  end

  def test_delete_of_a_problem_not_on_file_sends_no_write
    # DEL answers "" for an IEN not on file (BGOPROB3.m:18), as it does for a
    # delete; the read first is what tells them apart.
    client = replay_flow("delete_not_found")

    result = RpmsRpc::Problem.delete(DFN, 999_999, reason: "Entered in error")

    assert_equal({ success: false, ien: nil, raw: nil, error: :not_found }, result)
    assert_equal [ "DDR GETS ENTRY DATA" ], sent(client).map(&:first)
  end

  def test_delete_whose_read_back_is_not_deleted_is_not_filed
    # The delete flow's replies, with the read-back the problem had before
    # the delete (status I): a DEL that answered "" and left it in place.
    replay("DDR GETS ENTRY DATA" => [ reply("delete/1"), reply("delete/1") ], "BGOPROB DEL" => [ reply("delete/2") ])

    result = RpmsRpc::Problem.delete(DFN, IEN, reason: "Entered in error")

    refute result[:success]
    assert_equal :not_filed, result[:error]
  end

  # --- guards: nothing is sent ---------------------------------------------

  def test_invalid_ids_send_nothing
    client = replay({})

    assert_equal({ success: false, ien: nil, raw: nil }, RpmsRpc::Problem.add(nil, DEPRESSION))
    assert_equal({ success: false, ien: nil, raw: nil }, RpmsRpc::Problem.update("0", IEN, DEPRESSION))
    assert_equal({ success: false, ien: nil, raw: nil }, RpmsRpc::Problem.delete(DFN, nil, reason: "x"))
    assert_empty client.calls
  end

  def test_a_problem_that_is_not_a_hash_raises
    replay({})

    assert_raises(ArgumentError) { RpmsRpc::Problem.add(DFN, nil) }
    assert_raises(ArgumentError) { RpmsRpc::Problem.update(DFN, IEN, "not a hash") }
  end
end
