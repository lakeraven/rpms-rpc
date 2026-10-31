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

  APPT_IEN = 501
  RESOURCE_IEN = 88
  HOSPITAL_LOC = 1608

  START_T = Time.new(2026, 8, 12, 9, 0, 0)
  START_FM = RpmsRpc::FilemanDateParser.format_datetime(START_T)

  def setup
    RpmsRpc.mock!
  end

  def teardown
    RpmsRpc.reset!
  end

  def seed_gets(file:, iens:, fields:, flags: "I", text:)
    key = Ddr.gets_entry_param(file: file, iens: iens, fields: fields, flags: flags).to_s
    RpmsRpc.client.seed(:ddr_gets_entry_data, key, text)
  end

  def appointment_preflight_gets_param(ien)
    Ddr.gets_entry_param(file: "9002018.4", iens: "#{ien},", fields: ".03;.07", flags: "I")
  end

  def appointment_post_checkin_gets_param(ien)
    Ddr.gets_entry_param(file: "9002018.4", iens: "#{ien},", fields: ".03", flags: "I")
  end

  def resource_hospital_gets_param(resource_ien)
    Ddr.gets_entry_param(file: "9002018.1", iens: "#{resource_ien},", fields: ".04", flags: "I")
  end

  def seed_appointment_preflight(ien, checkin:, resource:)
    seed_gets(file: "9002018.4", iens: "#{ien},", fields: ".03;.07", text: <<~REPLY.strip)
      [Data]
      9002018.4^#{ien}^.03^#{checkin}^
      9002018.4^#{ien}^.07^#{resource}^
    REPLY
  end

  def seed_appointment_preflight_missing_checkin_row(ien, resource:)
    seed_gets(file: "9002018.4", iens: "#{ien},", fields: ".03;.07", text: <<~REPLY.strip)
      [Data]
      9002018.4^#{ien}^.07^#{resource}^
    REPLY
  end

  def seed_appointment_post_checkin(ien, checkin:)
    seed_gets(file: "9002018.4", iens: "#{ien},", fields: ".03", text: <<~REPLY.strip)
      [Data]
      9002018.4^#{ien}^.03^#{checkin}^
    REPLY
  end

  def seed_resource_hospital_loc(resource_ien, hospital_loc)
    seed_gets(file: "9002018.1", iens: "#{resource_ien},", fields: ".04", text: <<~REPLY.strip)
      [Data]
      9002018.1^#{resource_ien}^.04^#{hospital_loc}^
    REPLY
  end

  def seed_resource_hospital_loc_error(resource_ien)
    seed_gets(file: "9002018.1", iens: "#{resource_ien},", fields: ".04", text: "[ERROR]")
  end

  def seed_undo_checkin_graph(appt_ien: APPT_IEN, checkin: START_FM, resource: RESOURCE_IEN,
                              hospital: HOSPITAL_LOC, post_checkin: "")
    seed_appointment_preflight(appt_ien, checkin: checkin, resource: resource)
    seed_resource_hospital_loc(resource, hospital)
    RpmsRpc.client.seed(:scheduling_checkin_appointment, appt_ien.to_s, { error: "0" })
    seed_appointment_post_checkin(appt_ien, checkin: post_checkin)
  end

  def ddr_gets_calls
    RpmsRpc.client.received_calls.select { |c| c[:rpc] == "DDR GETS ENTRY DATA" }
  end

  def bsdx_checkin_calls
    RpmsRpc.client.received_calls.select { |c| c[:rpc] == "BSDX CHECKIN APPOINTMENT" }
  end

  def assert_scheduling_failure(result, error:)
    assert_kind_of Hash, result, "expected a result Hash, got #{result.inspect}"
    refute result[:success]
    assert_equal error, result[:error]
  end

  def assert_no_bsdx_checkin_rpc
    assert_empty bsdx_checkin_calls, bsdx_checkin_calls.inspect
  end

  def test_undo_checkin_success_uses_bsdx_checkin_appointment_with_at_time
    seed_undo_checkin_graph

    result = RpmsRpc::Scheduling.undo_checkin(APPT_IEN)

    assert result[:success]
    assert_equal 1, bsdx_checkin_calls.length
    call = bsdx_checkin_calls.first
    assert_equal "BSDX CHECKIN APPOINTMENT", call[:rpc]
    assert_equal "BSDXRPC", call[:context]
    assert_equal [ APPT_IEN.to_s, "@", "", "", "", "", "", "" ], call[:params]
    gets_params = ddr_gets_calls.map { |c| c[:params].first }
    assert_includes gets_params, appointment_preflight_gets_param(APPT_IEN)
    assert_includes gets_params, appointment_post_checkin_gets_param(APPT_IEN)
    assert_includes gets_params, resource_hospital_gets_param(RESOURCE_IEN)
  end

  def test_undo_checkin_sends_the_same_trailing_formals_as_checkin_appointment
    seed_undo_checkin_graph

    RpmsRpc::Scheduling.undo_checkin(APPT_IEN, clinic_code: "301", provider: "PROVIDER,A")

    assert_equal [ APPT_IEN.to_s, "@", "301", "PROVIDER,A", "", "", "", "" ], bsdx_checkin_calls.first[:params]
  end

  def test_undo_checkin_returns_not_undone_when_check_in_time_is_still_set
    seed_undo_checkin_graph(post_checkin: START_FM)

    result = RpmsRpc::Scheduling.undo_checkin(APPT_IEN)

    assert_scheduling_failure(result, error: :not_undone)
    refute_nil result[:message]
  end

  def test_undo_checkin_returns_not_checked_in_when_check_in_time_is_blank_before_the_rpc
    seed_appointment_preflight(APPT_IEN, checkin: "", resource: RESOURCE_IEN)

    result = RpmsRpc::Scheduling.undo_checkin(APPT_IEN)

    assert_scheduling_failure(result, error: :not_checked_in)
    assert_no_bsdx_checkin_rpc
  end

  def test_undo_checkin_returns_no_resource_when_resourceid_is_blank
    seed_appointment_preflight(APPT_IEN, checkin: START_FM, resource: "")

    result = RpmsRpc::Scheduling.undo_checkin(APPT_IEN)

    assert_scheduling_failure(result, error: :no_resource)
    assert_no_bsdx_checkin_rpc
  end

  def test_undo_checkin_returns_no_resource_when_hospital_location_is_blank
    seed_appointment_preflight(APPT_IEN, checkin: START_FM, resource: RESOURCE_IEN)
    seed_resource_hospital_loc(RESOURCE_IEN, "")

    result = RpmsRpc::Scheduling.undo_checkin(APPT_IEN)

    assert_scheduling_failure(result, error: :no_resource)
    assert_no_bsdx_checkin_rpc
  end

  def test_undo_checkin_returns_no_resource_when_hospital_location_read_errors
    seed_appointment_preflight(APPT_IEN, checkin: START_FM, resource: RESOURCE_IEN)
    seed_resource_hospital_loc_error(RESOURCE_IEN)

    result = RpmsRpc::Scheduling.undo_checkin(APPT_IEN)

    assert_scheduling_failure(result, error: :no_resource)
    assert_no_bsdx_checkin_rpc
  end

  def test_undo_checkin_returns_lookup_failed_when_the_preflight_read_fails
    seed_gets(file: "9002018.4", iens: "#{APPT_IEN},", fields: ".03;.07", text: "[ERROR]")

    result = RpmsRpc::Scheduling.undo_checkin(APPT_IEN)

    assert_scheduling_failure(result, error: :lookup_failed)
    assert_no_bsdx_checkin_rpc
  end

  def test_undo_checkin_returns_lookup_failed_when_the_preflight_read_gives_no_response
    result = RpmsRpc::Scheduling.undo_checkin(APPT_IEN)

    assert_scheduling_failure(result, error: :lookup_failed)
    assert_no_bsdx_checkin_rpc
  end

  def test_undo_checkin_returns_lookup_failed_when_the_preflight_read_is_missing_a_requested_row
    seed_appointment_preflight_missing_checkin_row(APPT_IEN, resource: RESOURCE_IEN)

    result = RpmsRpc::Scheduling.undo_checkin(APPT_IEN)

    assert_scheduling_failure(result, error: :lookup_failed)
    assert_no_bsdx_checkin_rpc
  end

  def test_undo_checkin_returns_lookup_failed_when_the_post_check_in_read_fails
    seed_appointment_preflight(APPT_IEN, checkin: START_FM, resource: RESOURCE_IEN)
    seed_resource_hospital_loc(RESOURCE_IEN, HOSPITAL_LOC)
    RpmsRpc.client.seed(:scheduling_checkin_appointment, APPT_IEN.to_s, { error: "0" })
    seed_gets(file: "9002018.4", iens: "#{APPT_IEN},", fields: ".03", text: "[ERROR]")

    result = RpmsRpc::Scheduling.undo_checkin(APPT_IEN)

    assert_scheduling_failure(result, error: :lookup_failed)
    assert_equal 1, bsdx_checkin_calls.length
  end

  def test_undo_checkin_returns_lookup_failed_when_the_post_check_in_read_is_missing_the_row
    seed_appointment_preflight(APPT_IEN, checkin: START_FM, resource: RESOURCE_IEN)
    seed_resource_hospital_loc(RESOURCE_IEN, HOSPITAL_LOC)
    RpmsRpc.client.seed(:scheduling_checkin_appointment, APPT_IEN.to_s, { error: "0" })
    seed_gets(file: "9002018.4", iens: "#{APPT_IEN},", fields: ".03", text: "[Data]")

    result = RpmsRpc::Scheduling.undo_checkin(APPT_IEN)

    assert_scheduling_failure(result, error: :lookup_failed)
    assert_equal 1, bsdx_checkin_calls.length
  end

  def test_undo_checkin_returns_lookup_failed_when_the_resource_read_gives_no_response
    seed_appointment_preflight(APPT_IEN, checkin: START_FM, resource: RESOURCE_IEN)

    result = RpmsRpc::Scheduling.undo_checkin(APPT_IEN)

    assert_scheduling_failure(result, error: :lookup_failed)
    assert_no_bsdx_checkin_rpc
  end

  def test_undo_checkin_returns_nil_when_the_broker_gives_no_response
    seed_appointment_preflight(APPT_IEN, checkin: START_FM, resource: RESOURCE_IEN)
    seed_resource_hospital_loc(RESOURCE_IEN, HOSPITAL_LOC)

    assert_nil RpmsRpc::Scheduling.undo_checkin(APPT_IEN)
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
