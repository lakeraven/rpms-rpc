# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/communication"

class CommunicationTest < Minitest::Test
  DFN = 8791
  DUZ = 301

  def setup
    RpmsRpc.mock! do |m|
      m.seed(:mailman_message, "2001", message_attrs(ien: 2001, status: "READ"))
      m.seed_keyed_collection(:mailman_messages_for_patient, DFN.to_s, [
        message_attrs(ien: 2001, status: "READ"),
        message_attrs(ien: 2002, subject: "Follow-up", status: "", priority: "")
      ])
      m.seed_keyed_collection(:mailman_thread, "T2001", [
        message_attrs(ien: 2001, thread_id: "T2001", sent_at: DateTime.new(2026, 1, 2, 10, 0, 0)),
        message_attrs(ien: 2003, subject: "RE: Care update", thread_id: "T2001",
          parent_id: 2001, sent_at: DateTime.new(2026, 1, 2, 11, 0, 0))
      ])
      m.seed_keyed_collection(:mailman_inbox, "#{DUZ}^IN", [
        message_attrs(ien: 2004, recipient_duz: DUZ, basket: "IN")
      ])
      m.seed_keyed_collection(:xqal_alert, DUZ.to_s, [
        {
          alert_ien: 501,
          user_duz: DUZ,
          message: "Review critical lab",
          created_at: DateTime.new(2026, 1, 3, 8, 30, 0),
          priority: "urgent",
          category: "alert",
          status: ""
        }
      ])
      m.seed(:mailman_send, "Care update^Please review\\nLine two^301,302^8791^routine^notification", {
        success: true,
        message_ien: 3001,
        error: nil
      })
      m.seed(:mailman_reply, "2001^Thanks\\nAcknowledged^1", {
        success: true,
        message_ien: 3002,
        thread_id: "T2001",
        error: nil
      })
      m.seed(:xqal_mark_read, "501^301", { success: true, error: nil })
      m.seed(:xqal_forward, "501^301^302^Please review", {
        success: true,
        new_alert_ien: 777,
        error: nil
      })
    end
  end

  def teardown
    RpmsRpc.reset!
  end

  def test_find_returns_mailman_message
    message = RpmsRpc::Communication.find(2001)

    refute_nil message
    assert_equal 2001, message[:ien]
    assert_equal DFN, message[:patient_dfn]
    assert_equal "Care update", message[:subject]
    assert_equal "READ", message[:status]
    assert_equal "routine", message[:priority]
  end

  def test_find_returns_nil_for_invalid_or_unknown_ien
    assert_nil RpmsRpc::Communication.find(nil)
    assert_nil RpmsRpc::Communication.find("")
    assert_nil RpmsRpc::Communication.find(0)
    assert_nil RpmsRpc::Communication.find(-1)
    assert_nil RpmsRpc::Communication.find("abc")
    assert_nil RpmsRpc::Communication.find(999_999)
  end

  def test_for_patient_returns_messages_and_defaults_blank_fields
    messages = RpmsRpc::Communication.for_patient(DFN)

    assert_equal 2, messages.length
    follow_up = messages.find { |m| m[:subject] == "Follow-up" }
    assert_equal "NEW", follow_up[:status]
    assert_equal "routine", follow_up[:priority]
  end

  def test_for_patient_rejects_blank_zero_negative_and_non_numeric_dfn
    assert_equal [], RpmsRpc::Communication.for_patient(nil)
    assert_equal [], RpmsRpc::Communication.for_patient("")
    assert_equal [], RpmsRpc::Communication.for_patient(0)
    assert_equal [], RpmsRpc::Communication.for_patient(-1)
    assert_equal [], RpmsRpc::Communication.for_patient("abc")
  end

  def test_search_filters_patient_messages
    results = RpmsRpc::Communication.search(patient_dfn: DFN, status: "READ")

    assert_equal 1, results.length
    assert_equal 2001, results.first[:ien]
  end

  def test_send_message_sends_write_payload_and_maps_result
    result = RpmsRpc::Communication.send_message(
      subject: "Care update",
      body: "Please review\nLine two",
      recipients: [ "301", "302" ],
      patient_dfn: DFN,
      category: "notification"
    )

    assert_equal({ success: true, message_id: 3001, error: nil }, result)
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "XM SEND MESSAGE" }
    assert_equal [ "Care update^Please review\\nLine two^301,302^8791^routine^notification" ], call[:params]
  end

  def test_send_message_validates_required_fields
    assert_raises(ArgumentError) { RpmsRpc::Communication.send_message(body: "Body", recipients: [ "301" ]) }
    assert_raises(ArgumentError) { RpmsRpc::Communication.send_message(subject: "Subject", recipients: [ "301" ]) }
    assert_raises(ArgumentError) { RpmsRpc::Communication.send_message(subject: "Subject", body: "Body") }
  end

  def test_send_message_rejects_whitespace_only_subject_or_body
    assert_raises(ArgumentError) do
      RpmsRpc::Communication.send_message(subject: "   ", body: "Body", recipients: [ "301" ])
    end
    assert_raises(ArgumentError) do
      RpmsRpc::Communication.send_message(subject: "Subject", body: "   ", recipients: [ "301" ])
    end
  end

  def test_reply_to_message_uses_parent_thread_context
    result = RpmsRpc::Communication.reply_to_message(2001, body: "Thanks\nAcknowledged", reply_all: true)

    assert_equal true, result[:success]
    assert_equal 3002, result[:message_id]
    assert_equal "T2001", result[:thread_id]
    assert_equal 2001, result[:parent_id]
  end

  def test_reply_to_message_rejects_invalid_parent_or_body
    assert_equal false, RpmsRpc::Communication.reply_to_message(nil, body: "Thanks")[:success]
    assert_equal false, RpmsRpc::Communication.reply_to_message(2001, body: "")[:success]
    assert_equal false, RpmsRpc::Communication.reply_to_message(2001, body: "   ")[:success]
    assert_equal false, RpmsRpc::Communication.reply_to_message(999_999, body: "Thanks")[:success]
  end

  def test_get_thread_returns_messages_in_chronological_order
    messages = RpmsRpc::Communication.get_thread("T2001")

    assert_equal [ 2001, 2003 ], messages.map { |m| m[:ien] }
  end

  def test_for_user_uses_duz_and_basket_composite_key
    messages = RpmsRpc::Communication.for_user(DUZ)

    assert_equal 1, messages.length
    assert_equal 2004, messages.first[:ien]
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "XM GET INBOX" }
    assert_equal [ "#{DUZ}^IN" ], call[:params]
  end

  def test_get_alerts_and_count_default_blank_status
    alerts = RpmsRpc::Communication.get_alerts(DUZ)

    assert_equal 1, alerts.length
    assert_equal 501, alerts.first[:alert_ien]
    assert_equal "NEW", alerts.first[:status]
    assert_equal 1, RpmsRpc::Communication.alert_count(DUZ)
  end

  def test_mark_alert_read_and_forward_alert_map_results
    assert_equal({ success: true, error: nil }, RpmsRpc::Communication.mark_alert_read(501, DUZ))
    assert_equal({ success: true, new_alert_ien: 777, error: nil },
      RpmsRpc::Communication.forward_alert(501, from_duz: DUZ, to_duz: 302, comment: "Please review"))
  end

  def test_alert_write_paths_reject_invalid_ids
    assert_equal false, RpmsRpc::Communication.mark_alert_read(0, DUZ)[:success]
    assert_equal false, RpmsRpc::Communication.mark_alert_read(501, 0)[:success]
    assert_equal false, RpmsRpc::Communication.forward_alert(0, from_duz: DUZ, to_duz: 302)[:success]
    assert_equal false, RpmsRpc::Communication.forward_alert(501, from_duz: 0, to_duz: 302)[:success]
    assert_equal false, RpmsRpc::Communication.forward_alert(501, from_duz: DUZ, to_duz: 0)[:success]
  end

  private

  def message_attrs(overrides = {})
    {
      ien: 2001,
      patient_dfn: DFN,
      sender_duz: 201,
      sender_name: "PROVIDER,SENDER",
      recipient_duz: DUZ,
      recipient_name: "PROVIDER,RECIPIENT",
      subject: "Care update",
      body: "Please review\nLine two",
      sent_at: DateTime.new(2026, 1, 2, 10, 0, 0),
      read_at: nil,
      status: "NEW",
      priority: "routine",
      category: "notification",
      parent_id: nil,
      thread_id: "T2001",
      basket: "IN"
    }.merge(overrides)
  end
end
