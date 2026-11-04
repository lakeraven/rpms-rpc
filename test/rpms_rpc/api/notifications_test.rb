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
end
