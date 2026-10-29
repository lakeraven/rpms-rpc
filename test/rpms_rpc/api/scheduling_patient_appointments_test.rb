# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc"

# Scheduling.patient_appointments (BSDX PATIENT APPT DISPLAY, PADISP^BSDX27):
# one patient's appointments across clinics (rpms-ux S-SCH-05.6). The reply rows
# are the ones a live rpms-ydb 7c3119b build answered for MOUSE,MICKEY M as
# PROFILE,SCHED (2026-10-29), its address pieces replaced; each row also carries the patient's address and
# phone, which this method does not return.
class SchedulingPatientAppointmentsTest < Minitest::Test
  class RecordsetClient
    attr_reader :calls

    def initialize(replies)
      @replies = replies
      @calls = []
      @context = "CIAV VUECENTRIC"
    end

    def with_context(name)
      before = @context
      @context = name
      yield
    ensure
      @context = before
    end

    def call_rpc_global_array(rpc, *params)
      @calls << { rpc: rpc, params: params, context: @context }
      @replies.fetch(rpc)
    end
  end

  HEADER = "T00030Name^D00020DOB^T00030Sex^T00030HRN^D00030ApptDate^T00030Clinic^T00030TypeStatus^I00010RESOURCEID^" \
           "T00030APPT_MADE_BY^D00020DATE_APPT_MADE^T00250NOTE^T00030STREET^T00030CITY^T00030STATE^T00030ZIP^T00030HOMEPHONE"
  ROWS = [
    "MOUSE,MICKEY M^FEB 14,1910^MALE^1001^NOV 5,2026 11:00^DEMO IHS CLINIC^SCHED^2^PROFILE,SCHED^OCT 29,2026 17:01:03^^1 DEMO STREET^DEMOTOWN^ST^00000^555-0100",
    "MOUSE,MICKEY M^FEB 14,1910^MALE^1001^OCT 29,2026 12:15^DEMO IHS CLINIC^SCHED - CHECKED IN^2^PROFILE,SCHED^OCT 29,2026 18:22:50^^1 DEMO STREET^DEMOTOWN^ST^00000^555-0100"
  ].freeze

  def use(reply)
    client = RecordsetClient.new("BSDX PATIENT APPT DISPLAY" => reply)
    RpmsRpc.configure { |c| c.client = client }
    client
  end

  def wire(*rows) = "1\x00#{([ HEADER ] + rows).join("\x1e")}\x1e\x1f"

  def teardown = RpmsRpc.reset!

  def test_each_appointment_with_its_clinic_type_status_and_who_made_it_when
    use(wire(*ROWS))

    first, second = RpmsRpc::Scheduling.patient_appointments(3)

    assert_equal({ start_time: Time.new(2026, 11, 5, 11, 0), clinic: "DEMO IHS CLINIC", resource_id: 2, type: "SCHED",
                   status: "scheduled", made_by: "PROFILE,SCHED", made_at: Time.new(2026, 10, 29, 17, 1, 3), note: nil }, first)
    assert_equal "checked in", second[:status]
  end

  def test_the_patients_address_and_phone_are_not_returned
    use(wire(*ROWS))

    keys = RpmsRpc::Scheduling.patient_appointments(3).flat_map(&:keys).uniq
    refute(keys.any? { |k| %i[street city state zip homephone name dob sex hrn].include?(k) })
  end

  def test_it_asks_for_the_patient_under_the_scheduling_context
    client = use(wire(*ROWS))

    RpmsRpc::Scheduling.patient_appointments(3)

    assert_equal [ { rpc: "BSDX PATIENT APPT DISPLAY", params: [ "3" ], context: "BSDXRPC" } ], client.calls
  end

  def test_a_patient_with_no_appointments_has_none
    use(wire)

    assert_equal [], RpmsRpc::Scheduling.patient_appointments(3)
  end

  # ERR^BSDX27 answers an error as one row of empty pieces.
  def test_the_routines_error_row_raises
    use(wire("^^^^^^^^^^^^^^^"))

    assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Scheduling.patient_appointments(3) }
  end
end
