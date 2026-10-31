# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/scheduling"

# rpms-rpc#418 scheduling row: undo check-in through BSDX CHECKIN APPOINTMENT
# with check-in time "@" (CANCHKIN^BSDX25), same contract as checkin_appointment.
class SchedulingBprm418Test < Minitest::Test
  Ddr = RpmsRpc::DdrFileman

  START_T = Time.new(2026, 8, 12, 9, 0, 0)
  START_FM = RpmsRpc::FilemanDateParser.format_datetime(START_T)

  def setup
    RpmsRpc.mock!
  end

  def teardown
    RpmsRpc.reset!
  end

  def appointment_checkin_gets_key(ien)
    Ddr.gets_entry_param(file: "9002018.4", iens: "#{ien},", fields: ".03", flags: "I").to_s
  end

  def seed_appointment_checkin_field(ien, internal)
    RpmsRpc.client.seed(:ddr_gets_entry_data, appointment_checkin_gets_key(ien), <<~REPLY.strip)
      [Data]
      9002018.4^#{ien}^.03^#{internal}^
    REPLY
  end

  def assert_scheduling_failure(result, error:)
    assert_kind_of Hash, result, "expected a result Hash, got #{result.inspect}"
    refute result[:success]
    assert_equal error, result[:error]
  end

  def test_undo_checkin_success_uses_bsdx_checkin_appointment_with_at_time
    RpmsRpc.client.seed(:scheduling_checkin_appointment, "501", { error: "0" })
    seed_appointment_checkin_field(501, "")

    result = RpmsRpc::Scheduling.undo_checkin(501)

    assert result[:success]
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BSDX CHECKIN APPOINTMENT" }
    assert_equal "BSDX CHECKIN APPOINTMENT", call[:rpc]
    assert_equal "BSDXRPC", call[:context]
    assert_equal [ "501", "@", "", "", "", "", "", "" ], call[:params]
    gets = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "DDR GETS ENTRY DATA" }
    refute_nil gets, "expected a post-check-in DDR GETS ENTRY DATA read of #9002018.4 field .03"
    assert_equal Ddr.gets_entry_param(file: "9002018.4", iens: "501,", fields: ".03", flags: "I"),
                 gets[:params].first
  end

  def test_undo_checkin_sends_the_same_trailing_formals_as_checkin_appointment
    RpmsRpc.client.seed(:scheduling_checkin_appointment, "501", { error: "0" })
    seed_appointment_checkin_field(501, "")

    RpmsRpc::Scheduling.undo_checkin(501, clinic_code: "301", provider: "PROVIDER,A")

    assert_equal [ "501", "@", "301", "PROVIDER,A", "", "", "", "" ],
                 RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BSDX CHECKIN APPOINTMENT" }[:params]
  end

  def test_undo_checkin_returns_not_undone_when_check_in_time_is_still_set
    RpmsRpc.client.seed(:scheduling_checkin_appointment, "501", { error: "0" })
    seed_appointment_checkin_field(501, START_FM)

    result = RpmsRpc::Scheduling.undo_checkin(501)

    assert_scheduling_failure(result, error: :not_undone)
    refute_nil result[:message]
  end

  def test_undo_checkin_returns_lookup_failed_when_the_appointment_read_fails
    RpmsRpc.client.seed(:scheduling_checkin_appointment, "501", { error: "0" })
    RpmsRpc.client.seed(:ddr_gets_entry_data, appointment_checkin_gets_key(501), "[ERROR]")

    result = RpmsRpc::Scheduling.undo_checkin(501)

    assert_scheduling_failure(result, error: :lookup_failed)
  end

  def test_undo_checkin_returns_lookup_failed_when_the_appointment_read_gives_no_response
    RpmsRpc.client.seed(:scheduling_checkin_appointment, "501", { error: "0" })

    result = RpmsRpc::Scheduling.undo_checkin(501)

    assert_scheduling_failure(result, error: :lookup_failed)
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
