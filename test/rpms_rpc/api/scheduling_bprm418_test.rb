# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/scheduling"

# rpms-rpc#418 scheduling row: undo check-in through BSDX CHECKIN APPOINTMENT
# with check-in time "@" (CANCHKIN^BSDX25), same contract as checkin_appointment.
class SchedulingBprm418Test < Minitest::Test
  START_T = Time.new(2026, 8, 12, 9, 0, 0)
  START_FM = RpmsRpc::FilemanDateParser.format_datetime(START_T)

  def setup
    RpmsRpc.mock!
  end

  def teardown
    RpmsRpc.reset!
  end

  def test_undo_checkin_success_uses_bsdx_checkin_appointment_with_at_time
    RpmsRpc.client.seed(:scheduling_checkin_appointment, "501", { error: "0" })

    result = RpmsRpc::Scheduling.undo_checkin(501)

    assert result[:success]
    call = RpmsRpc.client.received_calls.last
    assert_equal "BSDX CHECKIN APPOINTMENT", call[:rpc]
    assert_equal "BSDXRPC", call[:context]
    assert_equal [ "501", "@", "", "", "", "", "", "" ], call[:params]
  end

  def test_undo_checkin_sends_the_same_trailing_formals_as_checkin_appointment
    RpmsRpc.client.seed(:scheduling_checkin_appointment, "501", { error: "0" })

    RpmsRpc::Scheduling.undo_checkin(501, clinic_code: "301", provider: "PROVIDER,A")

    assert_equal [ "501", "@", "301", "PROVIDER,A", "", "", "", "" ],
                 RpmsRpc.client.received_calls.last[:params]
  end

  def test_undo_checkin_returns_nil_when_the_broker_gives_no_response
    assert_nil RpmsRpc::Scheduling.undo_checkin(501)
  end

  def test_undo_checkin_refuses_a_blank_appointment_ien_without_rpc
    [ nil, "", "0" ].each do |bad|
      result = RpmsRpc::Scheduling.undo_checkin(bad)

      refute result[:success], bad.inspect
      assert_equal :invalid, result[:error]
    end
    assert_empty RpmsRpc.client.received_calls
  end
end
