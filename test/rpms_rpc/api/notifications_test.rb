# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/version"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/notifications"

class NotificationsTest < Minitest::Test
  USER_DUZ = "301"
  NOTIF    = "5001"

  def teardown
    RpmsRpc.reset!
  end

  def test_inbox_returns_all_items_by_default
    RpmsRpc.mock! do |m|
      m.seed_keyed_collection(:notifications_inbox, USER_DUZ, [
        { id: 1, type: "ABNORMAL_LAB", patient_dfn: 8791, message: "Critical K", severity: "high",   read_at: nil },
        { id: 2, type: "REMINDER",    patient_dfn: 8791, message: "Follow-up",  severity: "low",    read_at: Time.now }
      ])
    end

    rows = RpmsRpc::Notifications.inbox(USER_DUZ)
    assert_equal 2, rows.length
  end

  def test_inbox_unread_true_filters_to_unread
    RpmsRpc.mock! do |m|
      m.seed_keyed_collection(:notifications_inbox, USER_DUZ, [
        { id: 1, type: "T", patient_dfn: 8791, message: "u",   severity: "high", read_at: nil },
        { id: 2, type: "T", patient_dfn: 8791, message: "r",   severity: "low",  read_at: Time.now }
      ])
    end

    rows = RpmsRpc::Notifications.inbox(USER_DUZ, unread: true)
    assert_equal 1, rows.length
    assert_equal 1, rows.first[:id]
  end

  def test_inbox_unread_false_filters_to_read
    RpmsRpc.mock! do |m|
      m.seed_keyed_collection(:notifications_inbox, USER_DUZ, [
        { id: 1, type: "T", patient_dfn: 8791, message: "u",   severity: "high", read_at: nil },
        { id: 2, type: "T", patient_dfn: 8791, message: "r",   severity: "low",  read_at: Time.now }
      ])
    end

    rows = RpmsRpc::Notifications.inbox(USER_DUZ, unread: false)
    assert_equal 1, rows.length
    assert_equal 2, rows.first[:id]
  end

  def test_inbox_blank_user_returns_empty
    assert_equal [], RpmsRpc::Notifications.inbox(nil)
    assert_equal [], RpmsRpc::Notifications.inbox("0")
  end

  def test_inbox_raises_on_non_boolean_unread_value
    RpmsRpc.mock! do |m|
      m.seed_keyed_collection(:notifications_inbox, USER_DUZ, [])
    end
    assert_raises(ArgumentError) { RpmsRpc::Notifications.inbox(USER_DUZ, unread: "false") }
    assert_raises(ArgumentError) { RpmsRpc::Notifications.inbox(USER_DUZ, unread: 0) }
    assert_raises(ArgumentError) { RpmsRpc::Notifications.inbox(USER_DUZ, unread: :no) }
  end

  def test_mark_read_dispatches_and_returns_success
    RpmsRpc.mock! do |m|
      m.seed_scalar(:notification_mark_read, NOTIF, "0")
    end

    result = RpmsRpc::Notifications.mark_read(NOTIF, USER_DUZ)
    assert result[:success]

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BQI MARK ALERT READ" }
    assert_equal [ NOTIF, USER_DUZ ], call[:params]
  end

  def test_mark_read_blank_args_return_failure
    refute RpmsRpc::Notifications.mark_read(nil, USER_DUZ)[:success]
    refute RpmsRpc::Notifications.mark_read(NOTIF, "0")[:success]
  end
end
