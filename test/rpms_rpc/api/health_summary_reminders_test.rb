# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/health_summary"
require_relative "../captured_replies"

# HealthSummary.clinical_reminders and reminder_detail (rpms-rpc#694), against
# the build's own replies (test/fixtures/captured_replies/orqqpx-reminders.yml),
# captured as PROFILE,MD for seed patient DFN 4 and replayed through CiaClient.
# The live round trip is test/live/health_summary_reminders_live_test.rb.
class HealthSummaryRemindersTest < Minitest::Test
  SLUG = "orqqpx-reminders"
  HS = RpmsRpc::HealthSummary

  def teardown
    RpmsRpc.reset!
  end

  def replay(script = {})
    client = CapturedReplies::ReplayCiaClient.new(script)
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def replay_flow(name) = replay(CapturedReplies.flow_script(SLUG, name))

  def sent(client) = client.calls.map { |c| [ c[:rpc], c[:params] ] }

  # REMDET(ORY,ORPT,ORIEN): the DFN and the reminder IEN as two parameters.
  def test_reminder_detail_sends_the_patient_and_the_reminder_as_two_parameters
    client = replay_flow("detail")
    detail = HS.reminder_detail(4, 211)

    assert_equal CapturedReplies.flow_calls(SLUG, "detail"), sent(client)
    assert_equal [ [ "ORQQPX REMINDER DETAIL", %w[4 211] ] ], sent(client)
    assert detail[:content].start_with?("Frequency: Due every 1 year for ages 1D to 110Y."), detail.inspect
    assert_includes detail[:content], "REMINDER DUE:"
  end

  # The frame the gem used to send: the build answers it with an M error, which
  # is why the two-parameter frame above is the one to send.
  def test_the_one_parameter_frame_is_an_m_error_on_the_build
    replay("ORQQPX REMINDER DETAIL" => [ CapturedReplies.raw(SLUG, "detail_one_parameter") ])

    error = assert_raises(RpmsRpc::Client::RpcError) do
      RpmsRpc.client.call_rpc("ORQQPX REMINDER DETAIL", "4^211")
    end
    assert_includes error.message, "REMDET+5^ORQQPX, Undefined local variable: ORIEN"
  end

  # REMIND^ORQQPX (OR*3.0*226) answers IEN^NAME^DUE DATE^LAST DONE^PRIORITY^
  # DUE FLAG^DIALOG^^^^WIPE: piece 3 is the due date, not a status.
  def test_clinical_reminders_reads_the_builds_row_pieces
    client = replay_flow("reminders")
    reminders = HS.clinical_reminders(4)

    assert_equal CapturedReplies.flow_calls(SLUG, "reminders"), sent(client)
    assert_equal [ 211, 274 ], reminders.map { |r| r[:ien] }
    tobacco = reminders.first
    assert_equal({ ien: 211, name: "Tobacco Screen", due_date: "DUE NOW", last_done: nil, priority: 2,
                   due_flag: 1, dialog: true, dialog_wipe: false },
                 tobacco.slice(:ien, :name, :due_date, :last_done, :priority, :due_flag, :dialog, :dialog_wipe))
    refute tobacco.key?(:status), "REMIND has no status piece"
  end

  def test_nothing_is_sent_for_an_invalid_patient_or_reminder
    client = replay
    assert_nil HS.reminder_detail(0, 211)
    assert_nil HS.reminder_detail(4, "x")
    assert_equal [], HS.clinical_reminders(0)
    assert_empty client.calls
  end
end
