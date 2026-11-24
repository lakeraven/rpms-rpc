# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/notifications"
require_relative "../captured_replies"

# RpmsRpc::Notifications reads and acts on what BEHOXQ ALRLIST, ALRPP,
# FORWARD and ALRMSG answered on the pinned build. The replies are
# test/fixtures/captured_replies/notifications.yml (spec
# tools/captured_replies/notifications.rb): five alerts sent through XQAL GUI
# ALERTS, beside the OR consult alert the image carries, replayed through
# CiaClient's own reply grammar. Each test checks the gem sent exactly the
# recorded calls. The round trip itself is test/live/notifications_live_test.rb.
class NotificationsTest < Minitest::Test
  SLUG = "notifications"
  KEEP_ID = "BEHOXQ,CAPKEEP;200;3261120.050509"
  REMOVABLE_ID = "BEHOXQ,CAPDEL;200;3261120.050509"
  NO_PATIENT_ID = "BEHOXQ,CAPNOPT;200;3261120.050509"
  TIU_ID = "TIU,CAPTIU;200;3261120.050509"
  FORWARD_ID = "BEHOXQ,CAPFWD;200;3261120.050509"
  ELSEWHERE_ID = "BEHOXQ,ELSE;9;3261104.1"

  def teardown
    RpmsRpc.reset!
  end

  def replay(flow)
    client = CapturedReplies::ReplayCiaClient.new(flow ? CapturedReplies.flow_script(SLUG, flow) : {})
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def sent(client) = client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params] ] }
  def recorded(flow) = CapturedReplies.flow_calls(SLUG, flow)

  def test_s_sgn_02_1_each_notification_carries_its_patient
    replay("inbox")
    rows = RpmsRpc::Notifications.inbox

    assert_equal 5, rows.size
    assert_equal({
      alert_id: KEEP_ID,
      patient_dfn: 3,
      patient_name: "MOUSE,MICKEY M",
      hrn: "1001",
      location: nil,
      message: "Review the visit.",
      delivered_at: Time.new(2026, 11, 20, 5, 5, 9),
      sender: "PROVIDER,TEST",
      priority: :high,
      info_only: false,
      removable: false,
      type: "BEHOXQ"
    }, rows.find { |r| r[:alert_id] == KEEP_ID })
    consult = rows.find { |r| r[:type] == "OR.27" }
    assert_equal [ 2, "USER,TEST", "123456", :moderate, true, "PROFILE,MD" ],
                 consult.values_at(:patient_dfn, :patient_name, :hrn, :priority, :removable, :sender)
  end

  def test_an_alert_with_no_patient_has_no_dfn_or_name
    replay("inbox")
    row = RpmsRpc::Notifications.inbox.find { |r| r[:alert_id] == NO_PATIENT_ID }

    assert_nil row[:patient_dfn], "ALRLIST sends DFN 0 for an alert with no patient"
    assert_nil row[:patient_name]
    assert_nil row[:hrn]
    assert_equal :high, row[:priority]
    assert_equal false, row[:info_only]
    assert_equal false, row[:removable]
    assert_equal "Staff meeting moved to 3 PM.", row[:message], "the XQADATA after it is not the message"
  end

  def test_the_read_sends_behoxq_alrlist_for_the_signed_on_user
    client = replay("inbox")
    RpmsRpc::Notifications.inbox

    assert_equal [ [ "BEHOXQ ALRLIST", [] ] ], sent(client), "ALRLIST reads DUZ: no user is passed"
    assert_equal recorded("inbox"), sent(client)
  end

  def test_a_patient_limits_the_read
    client = replay("inbox_patient")
    rows = RpmsRpc::Notifications.inbox(patient_dfn: 4)

    assert_equal recorded("inbox_patient"), sent(client)
    assert_equal [ [ "BEHOXQ ALRLIST", [ "4" ] ] ], sent(client)
    assert_equal [ NO_PATIENT_ID, TIU_ID ], rows.map { |r| r[:alert_id] }, "another patient's alerts are not listed"
  end

  def test_no_alerts_is_an_empty_list
    replay("inbox_empty")

    assert_equal [], RpmsRpc::Notifications.inbox
  end

  # -- remove / forward / message ---------------------------------------------

  def test_remove_sends_behoxq_alrpp_as_vuecentric_does_and_confirms_it_is_gone
    client = replay("remove")

    assert_equal({ alert_id: REMOVABLE_ID, removed: true }, RpmsRpc::Notifications.remove(REMOVABLE_ID))
    assert_equal recorded("remove"), sent(client), "listed, removed, confirmed"
    assert_equal [ "BEHOXQ ALRLIST", "BEHOXQ ALRPP", "BEHOXQ ALRLIST" ], sent(client).map(&:first)
  end

  def test_remove_refuses_an_alert_rpms_marks_not_removable_and_sends_nothing
    client = replay("remove_not_removable")

    error = assert_raises(RpmsRpc::Notifications::RefusedError) { RpmsRpc::Notifications.remove(KEEP_ID) }
    assert_match(/may not be removed/, error.message)
    assert_equal recorded("remove_not_removable"), sent(client)
    refute_includes sent(client).map(&:first), "BEHOXQ ALRPP"
  end

  def test_remove_refuses_an_alert_that_is_not_in_my_notifications
    client = replay("remove_not_listed")

    error = assert_raises(RpmsRpc::Notifications::RefusedError) { RpmsRpc::Notifications.remove(ELSEWHERE_ID) }
    assert_match(/not in your notifications/, error.message)
    assert_equal recorded("remove_not_listed"), sent(client)
    refute_includes sent(client).map(&:first), "BEHOXQ ALRPP"
  end

  # The TIU alert handler (#90460.021 entry 2) has no post-processing: ALRPP
  # answers its IEN, 2, and the alert is still listed.
  def test_remove_raises_when_the_alert_is_still_listed_afterwards
    client = replay("remove_still_listed")

    error = assert_raises(RpmsRpc::Notifications::RefusedError) { RpmsRpc::Notifications.remove(TIU_ID) }
    assert_match(/still listed/, error.message)
    assert_equal recorded("remove_still_listed"), sent(client)
  end

  def test_forward_sends_behoxq_forward_with_the_recipients_and_comment
    client = replay("forward")

    result = RpmsRpc::Notifications.forward(FORWARD_ID, to: 207, comment: "Please review today.")

    assert_equal({ alert_id: FORWARD_ID, forwarded_to: [ 207 ], comment: "Please review today." }, result)
    assert_equal recorded("forward"), sent(client)
    assert_equal [ "BEHOXQ FORWARD", [ FORWARD_ID, { "1" => "207" }, "Please review today." ] ], sent(client).last
  end

  def test_forward_refuses_an_alert_that_is_not_in_my_notifications
    client = replay("inbox")

    error = assert_raises(RpmsRpc::Notifications::RefusedError) do
      RpmsRpc::Notifications.forward(ELSEWHERE_ID, to: 207)
    end
    assert_match(/not in your notifications/, error.message)
    assert_equal recorded("inbox"), sent(client), "listed, then nothing more"
  end

  def test_forward_refuses_a_recipient_that_is_not_a_duz_and_a_comment_rpms_cannot_hold
    client = replay(nil)

    assert_raises(ArgumentError) { RpmsRpc::Notifications.forward(FORWARD_ID, to: []) }
    assert_raises(ArgumentError) { RpmsRpc::Notifications.forward(FORWARD_ID, to: "G.SCHEDULERS") }
    assert_raises(ArgumentError) { RpmsRpc::Notifications.forward(FORWARD_ID, to: 0) }
    assert_raises(ArgumentError) { RpmsRpc::Notifications.forward(FORWARD_ID, to: 207, comment: "a" * 246) }
    assert_raises(ArgumentError) { RpmsRpc::Notifications.forward(FORWARD_ID, to: 207, comment: "a^b") }
    assert_empty sent(client), "nothing is sent for an argument RPMS would not take"
  end

  def test_message_answers_the_forwarding_comment_first
    client = replay("message")

    assert_equal [ "Please review today." ], RpmsRpc::Notifications.message(FORWARD_ID)
    assert_equal recorded("message"), sent(client)
  end
end
