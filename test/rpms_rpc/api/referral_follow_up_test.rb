# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc"
require "rpms_rpc/api/referral"
require_relative "../captured_replies"

# Referral.record_follow_up, record_status and follow_up_state (rpms-rpc#722).
# Every reply is the build's (test/fixtures/captured_replies/referral-follow-up.yml),
# recorded as the provider test role on bcer-9.0-20261124-60d39b6-ydb after setup
# filed referral 1 (active), 2 (active, ADDITIONAL INFO 1, no INCLUDE flag Y) and
# 3 (cancelled), and replayed through CiaClient. Each test checks the gem sent
# exactly the recorded calls: the lock, the reads, the write and the read-back.
class ReferralFollowUpTest < Minitest::Test
  SLUG = "referral-follow-up"

  def teardown
    RpmsRpc.reset!
  end

  def replay(flow)
    @client = CapturedReplies::ReplayCiaClient.new(flow ? CapturedReplies.flow_script(SLUG, flow) : {})
    RpmsRpc.configure { |cfg| cfg.client = @client }
  end

  def sent = @client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params] ] }

  def update_frame = sent.find { |rpc, _| rpc == "BMC UPDATE REFERRAL" }&.last

  def assert_sent_the_recorded_calls(flow) = assert_equal(CapturedReplies.flow_calls(SLUG, flow), sent)

  # The date of service and a case note file, and the read-back decides it.
  # The frame is UPDREFRL's 35 parameters, so the YottaDB broker packs them as
  # P(1)..P(35); the time goes as FileMan's canonical digits (09:30 -> 093).
  def test_a_follow_up_files_the_date_and_a_case_note_and_reads_them_back
    replay("follow_up")

    result = RpmsRpc::Referral.record_follow_up("1", appointment_on: Date.new(2026, 12, 4), time: "09:30",
                                                     case_note: "Seen by cardiology")

    assert_equal({ success: true, appointment: "3261204.093", case_note_ien: "1", raw: "~`1" }, result)
    assert_sent_the_recorded_calls("follow_up")
    assert_equal 35, update_frame.size
    assert_equal [ "1", "^12/04/2026@093", "Seen by cardiology" ], update_frame.values_at(0, 11, 29).map { |v| v.sub(/\A\d*(?=\^)/, "") }
    assert_equal [ "DDR LOCK/UNLOCK NODE", "DDR LOCK/UNLOCK NODE" ], [ sent.first.first, sent.last.first ], "locked first, unlocked last"
  end

  # A note-only follow-up resends the 1106 on file, so the date stays.
  def test_a_note_only_follow_up_keeps_the_date_of_service
    replay("note_only")

    result = RpmsRpc::Referral.record_follow_up("1", case_note: "Called the patient")

    assert_equal [ true, "3261204.093", "2" ], result.values_at(:success, :appointment, :case_note_ien)
    assert_sent_the_recorded_calls("note_only")
  end

  def test_follow_up_state_reads_the_status_the_date_and_the_case_notes
    replay("state")

    assert_equal({ status: "A", appointment: "3261204.093",
                   case_notes: [ { ien: "1", date: "3261124", text: "Seen by cardiology" },
                                 { ien: "2", date: "3261124", text: "Called the patient" } ] },
                 RpmsRpc::Referral.follow_up_state("1"))
    assert_sent_the_recorded_calls("state")
  end

  # UPDREFRL files .34 from the INCLUDE flags (BMCRPC2.m:243-244): referral 2's
  # .34 of 1 with no flag Y would be rewritten as 0, so nothing is sent.
  def test_an_additional_info_flag_the_include_flags_would_clear_is_refused_before_the_update
    replay("additional_info")

    result = RpmsRpc::Referral.record_follow_up("2", case_note: "Not filed")

    assert_equal [ false, :additional_info_would_change ], result.values_at(:success, :error)
    assert_nil update_frame
    assert_sent_the_recorded_calls("additional_info")
  end

  def test_a_closed_referral_and_one_not_on_file_are_refused_before_the_update
    { "closed" => [ "3", :closed ], "not_on_file" => [ "999999", :not_found ] }.each do |flow, (ien, error)|
      replay(flow)

      assert_equal [ false, error ], RpmsRpc::Referral.record_follow_up(ien, case_note: "Not filed").values_at(:success, :error), flow
      assert_nil update_frame, flow
      assert_sent_the_recorded_calls(flow)
    end
  end

  def test_record_status_files_a_checked_status_and_reads_it_back
    replay("status")
    assert_equal({ success: true, status: "A1", previous_status: "A", raw: "1" }, RpmsRpc::Referral.record_status("1", "A1"))
    assert_sent_the_recorded_calls("status")

    replay("status_back")
    assert_equal({ success: true, status: "A", previous_status: "A1", raw: "1" }, RpmsRpc::Referral.record_status("1", "A"))
    assert_sent_the_recorded_calls("status_back")
  end

  def test_record_status_of_a_referral_not_on_file_is_refused_before_the_update
    replay("status_not_on_file")

    assert_equal [ false, :not_found ], RpmsRpc::Referral.record_status("999999", "A1").values_at(:success, :error)
    refute(sent.any? { |rpc, _| rpc == "BMC REFERRAL STATUS UPDATE" })
    assert_sent_the_recorded_calls("status_not_on_file")
  end

  # Input the routine would file wrongly is refused before anything is sent.
  def test_bad_input_is_refused_without_the_wire
    replay(nil)

    assert_equal :invalid_ien, RpmsRpc::Referral.record_follow_up("1x", case_note: "n")[:error]
    assert_equal :invalid_ien, RpmsRpc::Referral.record_status("0", "A")[:error]
    assert_equal :invalid_status, RpmsRpc::Referral.record_status("1", "H")[:error]
    assert_equal :nothing_to_file, RpmsRpc::Referral.record_follow_up("1")[:error]
    assert_equal :invalid_date, RpmsRpc::Referral.record_follow_up("1", appointment_on: Date.new(1990, 1, 1), time: "09:30")[:error]
    assert_raises(ArgumentError) { RpmsRpc::Referral.record_follow_up("1", time: "09:30", case_note: "n") }
    assert_raises(ArgumentError) { RpmsRpc::Referral.record_follow_up("1", appointment_on: Date.new(2026, 12, 4), time: "00:00") }
    assert_empty sent
  end
end
