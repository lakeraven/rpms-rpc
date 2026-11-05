# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/notifications"

# RpmsRpc::Notifications.inbox reads what BEHOXQ ALRLIST answers: the rows
# below are the reply a rpms-ydb e9b78c8 container gave PROFILE,MD on
# 2026-11-04, after three alerts were sent to that user through Kernel's
# XQAL GUI ALERTS (SEND): two OE/RR UNSCHEDULED VISIT notifications for the
# demo patient MOUSE,MICKEY M, and one IHS EHR (BEHOXQ) alert with no patient.
# The layout is ALRLIST^BEHOXQ's (mappings/ihs.rb, :notifications_inbox).
class NotificationsTest < Minitest::Test
  CAPTURED = [
    "1^0^^  ^Staff meeting moved to 3 PM.^3261104.175352^MANAGER,SYSTEM^0^BEHOXQ^BEHOXQ,PROBE;4;3261104.175352^0^PRI=1^INF=0",
    "2^1^MOUSE,MICKEY M    (1001)^  ^Unscheduled visit.^3261104.174742^POSTMASTER^3^OR.19^OR,3,19;.5;3261104.174742^1^",
    "2^1^MOUSE,MICKEY M    (1001)^  ^Unscheduled visit (probe).^3261104.175206^MANAGER,SYSTEM^3^OR.19^OR,3,19;4;3261104.175206^1^"
  ].freeze

  def setup
    RpmsRpc.mock! do |m|
      m.seed_raw_lines(:notifications_inbox, "", CAPTURED)
      m.seed_raw_lines(:notifications_inbox, "4", CAPTURED.first(1))
    end
  end

  def teardown
    RpmsRpc.reset!
  end

  def test_s_sgn_02_1_each_notification_carries_its_patient
    rows = RpmsRpc::Notifications.inbox

    assert_equal 3, rows.size
    visit = rows[1]
    assert_equal({
      alert_id: "OR,3,19;.5;3261104.174742",
      patient_dfn: 3,
      patient_name: "MOUSE,MICKEY M",
      hrn: "1001",
      location: nil,
      message: "Unscheduled visit.",
      delivered_at: Time.new(2026, 11, 4, 17, 47, 42),
      sender: "POSTMASTER",
      priority: :moderate,
      info_only: true,
      removable: true,
      type: "OR.19"
    }, visit)
  end

  def test_an_alert_with_no_patient_has_no_dfn_or_name
    row = RpmsRpc::Notifications.inbox.first

    assert_nil row[:patient_dfn], "ALRLIST sends DFN 0 for an alert with no patient"
    assert_nil row[:patient_name]
    assert_nil row[:hrn]
    assert_equal :high, row[:priority]
    assert_equal false, row[:info_only]
    assert_equal false, row[:removable]
    assert_equal "Staff meeting moved to 3 PM.", row[:message], "the XQADATA after it is not the message"
  end

  def test_the_read_sends_behoxq_alrlist_for_the_signed_on_user
    RpmsRpc::Notifications.inbox

    call = RpmsRpc.client.received_calls.last
    assert_equal "BEHOXQ ALRLIST", call[:rpc]
    assert_empty call[:params].to_a, "ALRLIST reads DUZ: no user is passed"
  end

  def test_a_patient_limits_the_read
    rows = RpmsRpc::Notifications.inbox(patient_dfn: 4)

    assert_equal [ "4" ], RpmsRpc.client.received_calls.last[:params].to_a
    assert_equal [ "BEHOXQ,PROBE;4;3261104.175352" ], rows.map { |r| r[:alert_id] }
  end

  def test_no_alerts_is_an_empty_list
    RpmsRpc.mock! { |m| m.seed_raw_lines(:notifications_inbox, "", []) }

    assert_equal [], RpmsRpc::Notifications.inbox
  end

  # -- remove / forward / message ---------------------------------------------
  #
  # Replies a rpms-ydb e9b78c8 container gave on 2026-11-04: MANAGER,SYSTEM
  # sent itself a BEHOXQ alert marked XQACNDEL=1 (CAN DELETE), then forwarded
  # it to PROFILE,SCHED with a comment. BEHOXQ ALRPP answers the alert
  # handler's IEN (3, the BEHOXQ handler in #90460.021), whether or not that
  # handler deleted anything; BEHOXQ FORWARD answers 0 always (BEHOXQ.m:56-59).
  REMOVABLE = "1^0^MOUSE,MICKEY M    (1001)^  ^Lab result to review.^3261104.195631^MANAGER,SYSTEM^3^BEHOXQ^" \
              "BEHOXQ,PROBE4;4;3261104.195631^1^DFN=3^PRI=1^INF=0"
  REMOVABLE_ID = "BEHOXQ,PROBE4;4;3261104.195631"
  NOT_REMOVABLE_ID = "BEHOXQ,PROBE;4;3261104.175352" # CAPTURED.first: CAN DELETE 0

  # The mock answers the seeded inbox until +rpc+ is sent, then +after+:
  # the two ALRLIST replies the container gave before and after the write.
  def inbox_changes_after(rpc, after)
    RpmsRpc.client.define_singleton_method(:call_rpc) do |name, *params|
      reply = super(name, *params)
      seed_raw_lines(:notifications_inbox, "", after) if name == rpc
      reply
    end
  end

  def seed_removable(handler: "3")
    RpmsRpc.mock! do |m|
      m.seed_raw_lines(:notifications_inbox, "", [ REMOVABLE ] + CAPTURED)
      m.seed_raw_lines(:notifications_remove, REMOVABLE_ID, [ handler ])
    end
  end

  def sent_rpcs = RpmsRpc.client.received_calls.map { |c| c[:rpc] }

  def test_remove_sends_behoxq_alrpp_as_vuecentric_does_and_confirms_it_is_gone
    seed_removable
    inbox_changes_after("BEHOXQ ALRPP", CAPTURED)

    assert_equal({ alert_id: REMOVABLE_ID, removed: true }, RpmsRpc::Notifications.remove(REMOVABLE_ID))

    assert_equal [ "BEHOXQ ALRLIST", "BEHOXQ ALRPP", "BEHOXQ ALRLIST" ], sent_rpcs, "listed, removed, confirmed"
    assert_equal [ REMOVABLE_ID ], RpmsRpc.client.received_calls[1][:params].to_a
  end

  def test_remove_refuses_an_alert_rpms_marks_not_removable_and_sends_nothing
    seed_removable

    error = assert_raises(RpmsRpc::Notifications::RefusedError) { RpmsRpc::Notifications.remove(NOT_REMOVABLE_ID) }
    assert_match(/may not be removed/, error.message)
    refute_includes sent_rpcs, "BEHOXQ ALRPP"
  end

  def test_remove_refuses_an_alert_that_is_not_in_my_notifications
    seed_removable

    error = assert_raises(RpmsRpc::Notifications::RefusedError) { RpmsRpc::Notifications.remove("BEHOXQ,ELSE;9;3261104.1") }
    assert_match(/not in your notifications/, error.message)
    refute_includes sent_rpcs, "BEHOXQ ALRPP"
  end

  def test_remove_raises_when_the_alert_is_still_listed_afterwards
    seed_removable # the inbox never changes: the handler deleted nothing

    error = assert_raises(RpmsRpc::Notifications::RefusedError) { RpmsRpc::Notifications.remove(REMOVABLE_ID) }
    assert_match(/still listed/, error.message)
  end

  def test_remove_raises_when_no_alert_handler_matched
    seed_removable(handler: "0")

    error = assert_raises(RpmsRpc::Notifications::RefusedError) { RpmsRpc::Notifications.remove(REMOVABLE_ID) }
    assert_match(/no alert handler/, error.message)
  end

  def test_forward_sends_behoxq_forward_with_the_recipients_and_comment
    seed_removable
    RpmsRpc.client.seed_raw_lines(:notifications_forward, REMOVABLE_ID, [ "0" ])

    result = RpmsRpc::Notifications.forward(REMOVABLE_ID, to: 208, comment: "Please review today.")

    assert_equal({ alert_id: REMOVABLE_ID, forwarded_to: [ 208 ], comment: "Please review today." }, result)
    call = RpmsRpc.client.received_calls.last
    assert_equal "BEHOXQ FORWARD", call[:rpc]
    assert_equal [ REMOVABLE_ID, { "1" => "208" }, "Please review today." ], call[:params].to_a
  end

  def test_forward_refuses_an_alert_that_is_not_in_my_notifications
    seed_removable

    error = assert_raises(RpmsRpc::Notifications::RefusedError) do
      RpmsRpc::Notifications.forward("BEHOXQ,ELSE;9;3261104.1", to: 208)
    end
    assert_match(/not in your notifications/, error.message)
    refute_includes sent_rpcs, "BEHOXQ FORWARD"
  end

  def test_forward_refuses_a_recipient_that_is_not_a_duz_and_a_comment_rpms_cannot_hold
    seed_removable

    assert_raises(ArgumentError) { RpmsRpc::Notifications.forward(REMOVABLE_ID, to: []) }
    assert_raises(ArgumentError) { RpmsRpc::Notifications.forward(REMOVABLE_ID, to: "G.SCHEDULERS") }
    assert_raises(ArgumentError) { RpmsRpc::Notifications.forward(REMOVABLE_ID, to: 0) }
    assert_raises(ArgumentError) { RpmsRpc::Notifications.forward(REMOVABLE_ID, to: 208, comment: "a" * 246) }
    assert_raises(ArgumentError) { RpmsRpc::Notifications.forward(REMOVABLE_ID, to: 208, comment: "a^b") }
    assert_empty RpmsRpc.client.received_calls, "nothing is sent for an argument RPMS would not take"
  end

  def test_message_answers_the_forwarding_comment_first
    RpmsRpc.mock! { |m| m.seed_raw_lines(:notifications_message, REMOVABLE_ID, [ "Please review today." ]) }

    assert_equal [ "Please review today." ], RpmsRpc::Notifications.message(REMOVABLE_ID)
    assert_equal "BEHOXQ ALRMSG", RpmsRpc.client.received_calls.last[:rpc]
  end
end
