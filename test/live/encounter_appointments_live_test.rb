# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/encounter"

# Encounter.for_patient reads ORWPT APPTLST (APPTLST^ORWPT). When the
# scheduling read fails, the build answers SDA^ORQRY01's one row with no
# time, "^Error encountered^Error encountered"; the gem raises instead of
# listing it as a visit (rpms-rpc#679). ORWPT APPTLST is in CIAV VUECENTRIC;
# the spec reads only.
class EncounterAppointmentsLiveTest < LiveSpec::Test
  CONTEXT = "CIAV VUECENTRIC"
  NO_PATIENT = 1 # no PATIENT (#2) entry on the pinned build: VAERR 1
  DEMO = 4 # DEMO,PATIENT ONE on the pinned build: no appointment in APPTLST's window

  def test_a_failed_scheduling_read_raises
    error = assert_raises(RpmsRpc::Client::RpcError) do
      client.with_context(CONTEXT) { RpmsRpc::Encounter.for_patient(NO_PATIENT) }
    end

    assert_equal "ORWPT APPTLST could not read appointments for patient #{NO_PATIENT}: Error encountered", error.message
  end

  def test_a_patient_with_no_appointment_reads_empty
    assert_equal [], client.with_context(CONTEXT) { RpmsRpc::Encounter.for_patient(DEMO) }
  end
end
