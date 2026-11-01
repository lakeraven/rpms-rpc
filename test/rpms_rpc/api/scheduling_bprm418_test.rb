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
  PATIENT_DFN = 100
  OTHER_PATIENT_DFN = 101
  SUB_IEN = 7
  OTHER_SUB_IEN = 6

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

  # rpms-rpc#418, owner decision 2026-10-31: CANCHKIN^BSDX25 discards its own
  # FILE^DIE error and replies "0^", so #44.003 field 309 must be read back.
  # The appointment's #44.003 entry is found by listing the clinic day
  # (",<start>,<hospital location>,") and taking the row whose .01 is the
  # appointment's patient (the FIND^BSDX25 rule), start and patient coming
  # from #9002018.4 .01 and .05.
  def appointment_start_patient_gets_param(ien)
    Ddr.gets_entry_param(file: "9002018.4", iens: "#{ien},", fields: ".01;.05", flags: "I")
  end

  def clinic_appointment_lister_param(start, hospital)
    Ddr.lister_param(file: "44.003", iens: ",#{start},#{hospital},", fields: "@;.01I;309I", flags: "IP")
  end

  def seed_appointment_start_patient(ien, start: START_FM, patient: PATIENT_DFN)
    seed_gets(file: "9002018.4", iens: "#{ien},", fields: ".01;.05", text: <<~REPLY.strip)
      [Data]
      9002018.4^#{ien}^.01^#{start}^
      9002018.4^#{ien}^.05^#{patient}^
    REPLY
  end

  # rows: [[sub_ien, patient_dfn, field_309], ...]
  def seed_clinic_appointments(rows, start: START_FM, hospital: HOSPITAL_LOC)
    key = clinic_appointment_lister_param(start, hospital).to_s
    body = rows.map { |sub, dfn, f309| "#{sub}^#{dfn}^#{f309}" }.join("\n")
    RpmsRpc.client.seed(:ddr_lister, key, "[Data]\n#{body}")
  end

  def clinic_lister_calls
    RpmsRpc.client.received_calls.select { |c| c[:rpc] == "DDR LISTER" }
  end

  def seed_undo_checkin_graph(appt_ien: APPT_IEN, checkin: START_FM, resource: RESOURCE_IEN,
                              hospital: HOSPITAL_LOC, post_checkin: "", checkin_rpc: { error: "0" },
                              clinic_rows: [ [ SUB_IEN, PATIENT_DFN, "" ] ])
    seed_appointment_preflight(appt_ien, checkin: checkin, resource: resource)
    seed_resource_hospital_loc(resource, hospital)
    RpmsRpc.client.seed(:scheduling_checkin_appointment, appt_ien.to_s, checkin_rpc)
    seed_appointment_post_checkin(appt_ien, checkin: post_checkin)
    seed_appointment_start_patient(appt_ien)
    seed_clinic_appointments(clinic_rows, hospital: hospital) if clinic_rows
  end

  CANCHKIN_ERR = "Could not locate appointment..."

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

  # -- #44.003 field 309 read-back (rpms-rpc#418 owner decision) -------------

  def test_undo_checkin_reads_field_309_of_the_patients_clinic_appointment_after_a_clean_reply
    seed_undo_checkin_graph

    result = RpmsRpc::Scheduling.undo_checkin(APPT_IEN)

    assert result[:success], result.inspect
    assert_equal 1, bsdx_checkin_calls.length
    gets_params = ddr_gets_calls.map { |c| c[:params].first }
    assert_includes gets_params, appointment_start_patient_gets_param(APPT_IEN)
    assert_equal [ clinic_appointment_lister_param(START_FM, HOSPITAL_LOC) ],
                 clinic_lister_calls.map { |c| c[:params].first }
    assert_equal "CIAV VUECENTRIC", clinic_lister_calls.first[:context]
  end

  def test_undo_checkin_reports_partial_when_field_309_is_still_set_after_a_clean_reply
    seed_undo_checkin_graph(clinic_rows: [ [ SUB_IEN, PATIENT_DFN, START_FM ] ])

    result = RpmsRpc::Scheduling.undo_checkin(APPT_IEN)

    assert_scheduling_failure(result, error: :partial)
    assert_match(/309/, result[:message].to_s)
    assert_match(/44\.003|clinic/i, result[:message].to_s)
    assert_equal 1, bsdx_checkin_calls.length
  end

  def test_undo_checkin_judges_field_309_on_the_row_for_this_patient_only
    seed_undo_checkin_graph(clinic_rows: [ [ OTHER_SUB_IEN, OTHER_PATIENT_DFN, START_FM ],
                                           [ SUB_IEN, PATIENT_DFN, "" ] ])

    result = RpmsRpc::Scheduling.undo_checkin(APPT_IEN)

    assert result[:success], "another patient's check-in must not fail this undo: #{result.inspect}"
  end

  def test_undo_checkin_reports_partial_when_only_this_patients_row_has_309_set
    seed_undo_checkin_graph(clinic_rows: [ [ OTHER_SUB_IEN, OTHER_PATIENT_DFN, "" ],
                                           [ SUB_IEN, PATIENT_DFN, START_FM ] ])

    assert_scheduling_failure(RpmsRpc::Scheduling.undo_checkin(APPT_IEN), error: :partial)
  end

  def test_undo_checkin_is_partial_unverified_when_no_clinic_row_belongs_to_the_patient
    seed_undo_checkin_graph(clinic_rows: [ [ OTHER_SUB_IEN, OTHER_PATIENT_DFN, "" ] ])

    result = RpmsRpc::Scheduling.undo_checkin(APPT_IEN)

    assert_scheduling_failure(result, error: :partial_unverified)
  end

  def test_undo_checkin_is_partial_unverified_when_the_clinic_listing_is_empty
    seed_undo_checkin_graph(clinic_rows: [])

    assert_scheduling_failure(RpmsRpc::Scheduling.undo_checkin(APPT_IEN), error: :partial_unverified)
  end

  def test_undo_checkin_is_partial_unverified_when_the_clinic_listing_gives_no_reply
    seed_undo_checkin_graph(clinic_rows: nil)

    assert_scheduling_failure(RpmsRpc::Scheduling.undo_checkin(APPT_IEN), error: :partial_unverified)
  end

  def test_undo_checkin_is_partial_unverified_when_the_clinic_listing_errors
    seed_undo_checkin_graph(clinic_rows: nil)
    RpmsRpc.client.seed(:ddr_lister, clinic_appointment_lister_param(START_FM, HOSPITAL_LOC).to_s,
                        "[Errors]\n[BEGIN_diERRORS]\n202^^^\nboom\n[END_diERRORS]")

    assert_scheduling_failure(RpmsRpc::Scheduling.undo_checkin(APPT_IEN), error: :partial_unverified)
  end

  def test_undo_checkin_is_partial_unverified_when_the_start_and_patient_read_fails
    seed_undo_checkin_graph
    seed_gets(file: "9002018.4", iens: "#{APPT_IEN},", fields: ".01;.05", text: "[ERROR]")

    assert_scheduling_failure(RpmsRpc::Scheduling.undo_checkin(APPT_IEN), error: :partial_unverified)
  end

  def test_undo_checkin_is_partial_unverified_when_the_start_and_patient_read_omits_the_patient_row
    seed_undo_checkin_graph
    seed_gets(file: "9002018.4", iens: "#{APPT_IEN},", fields: ".01;.05", text: <<~REPLY.strip)
      [Data]
      9002018.4^#{APPT_IEN}^.01^#{START_FM}^
    REPLY

    assert_scheduling_failure(RpmsRpc::Scheduling.undo_checkin(APPT_IEN), error: :partial_unverified)
  end

  # Gate round 1 (A): once the check-in RPC has run and .03 is cleared, a
  # failure to verify field 309 is NOT a retry-safe lookup failure (a retry
  # preflights .03, finds it empty and answers :not_checked_in, hiding a
  # possibly-set 309). It is :partial_unverified and says so.
  def assert_partial_unverified(result)
    assert_scheduling_failure(result, error: :partial_unverified)
    message = result[:message].to_s
    assert_match(/\.03/, message)
    assert_match(/clear/i, message)
    assert_match(/309/, message)
    assert_match(/verif/i, message)
    assert_equal 1, bsdx_checkin_calls.length
  end

  def test_undo_checkin_is_partial_unverified_when_the_clinic_listing_has_two_rows_for_the_patient
    seed_undo_checkin_graph(clinic_rows: [ [ SUB_IEN, PATIENT_DFN, "" ],
                                           [ OTHER_SUB_IEN, PATIENT_DFN, START_FM ] ])

    assert_partial_unverified(RpmsRpc::Scheduling.undo_checkin(APPT_IEN))
  end

  def test_undo_checkin_two_patient_rows_are_never_judged_empty_even_when_both_309_are_empty
    seed_undo_checkin_graph(clinic_rows: [ [ SUB_IEN, PATIENT_DFN, "" ],
                                           [ OTHER_SUB_IEN, PATIENT_DFN, "" ] ])

    result = RpmsRpc::Scheduling.undo_checkin(APPT_IEN)

    refute result[:success], result.inspect
    assert_scheduling_failure(result, error: :partial_unverified)
  end

  def test_undo_checkin_is_partial_unverified_when_the_clinic_listing_is_unfinished
    seed_undo_checkin_graph(clinic_rows: nil)
    RpmsRpc.client.seed(:ddr_lister, clinic_appointment_lister_param(START_FM, HOSPITAL_LOC).to_s,
                        "[Misc]\nMORE^#{SUB_IEN}^#{SUB_IEN}\n[Data]\n#{SUB_IEN}^#{PATIENT_DFN}^")

    assert_partial_unverified(RpmsRpc::Scheduling.undo_checkin(APPT_IEN))
  end

  def test_undo_checkin_is_partial_unverified_when_the_patients_row_carries_no_309_piece
    seed_undo_checkin_graph(clinic_rows: nil)
    RpmsRpc.client.seed(:ddr_lister, clinic_appointment_lister_param(START_FM, HOSPITAL_LOC).to_s,
                        "[Data]\n#{SUB_IEN}^#{PATIENT_DFN}")

    assert_partial_unverified(RpmsRpc::Scheduling.undo_checkin(APPT_IEN))
  end

  def test_undo_checkin_is_partial_unverified_when_the_start_or_patient_is_empty
    seed_undo_checkin_graph
    seed_appointment_start_patient(APPT_IEN, patient: "")

    assert_partial_unverified(RpmsRpc::Scheduling.undo_checkin(APPT_IEN))
  end

  def test_undo_checkin_unverified_results_are_distinct_from_lookup_failed
    seed_undo_checkin_graph(clinic_rows: [])

    result = RpmsRpc::Scheduling.undo_checkin(APPT_IEN)

    refute_equal :lookup_failed, result[:error]
  end

  # Gate round 1 (B): an error reply with .03 already empty must read 309
  # through the same clinic listing before it answers.
  def test_undo_checkin_after_error_with_cleared_03_reports_partial_naming_309_when_it_is_set
    seed_undo_checkin_graph(checkin_rpc: { error: CANCHKIN_ERR }, post_checkin: "",
                            clinic_rows: [ [ SUB_IEN, PATIENT_DFN, START_FM ] ])

    result = RpmsRpc::Scheduling.undo_checkin(APPT_IEN)

    assert_scheduling_failure(result, error: :partial)
    assert_match(/309/, result[:message].to_s)
    assert_equal [ clinic_appointment_lister_param(START_FM, HOSPITAL_LOC) ],
                 clinic_lister_calls.map { |c| c[:params].first }
    assert_equal 1, bsdx_checkin_calls.length
  end

  def test_undo_checkin_after_error_with_cleared_03_and_empty_309_keeps_the_cleared_clinic_outcome
    seed_undo_checkin_graph(checkin_rpc: { error: CANCHKIN_ERR }, post_checkin: "",
                            clinic_rows: [ [ SUB_IEN, PATIENT_DFN, "" ] ])

    result = RpmsRpc::Scheduling.undo_checkin(APPT_IEN)

    refute result[:success], "an error reply is never success: #{result.inspect}"
    refute_includes %i[partial_unverified lookup_failed], result[:error],
                    "309 was read and is empty; the outcome is not an unverified one"
    assert_equal [ clinic_appointment_lister_param(START_FM, HOSPITAL_LOC) ],
                 clinic_lister_calls.map { |c| c[:params].first },
                 "309 must be read, not assumed"
  end

  def test_undo_checkin_after_error_with_cleared_03_is_partial_unverified_when_the_listing_is_unreadable
    seed_undo_checkin_graph(checkin_rpc: { error: CANCHKIN_ERR }, post_checkin: "", clinic_rows: nil)

    assert_partial_unverified(RpmsRpc::Scheduling.undo_checkin(APPT_IEN))
  end

  def test_undo_checkin_after_error_with_cleared_03_is_partial_unverified_when_two_rows_match
    seed_undo_checkin_graph(checkin_rpc: { error: CANCHKIN_ERR }, post_checkin: "",
                            clinic_rows: [ [ SUB_IEN, PATIENT_DFN, "" ], [ OTHER_SUB_IEN, PATIENT_DFN, "" ] ])

    assert_partial_unverified(RpmsRpc::Scheduling.undo_checkin(APPT_IEN))
  end

  def test_undo_checkin_after_error_with_set_03_does_not_read_309
    seed_undo_checkin_graph(checkin_rpc: { error: CANCHKIN_ERR }, post_checkin: START_FM)

    RpmsRpc::Scheduling.undo_checkin(APPT_IEN)

    assert_empty clinic_lister_calls
  end

  def test_undo_checkin_lists_the_clinic_day_at_the_appointments_own_start_and_hospital_location
    other_start = "3260813.1030"
    other_loc = 1700
    seed_undo_checkin_graph(hospital: other_loc, clinic_rows: nil)
    seed_appointment_start_patient(APPT_IEN, start: other_start)
    seed_clinic_appointments([ [ SUB_IEN, PATIENT_DFN, "" ] ], start: other_start, hospital: other_loc)

    result = RpmsRpc::Scheduling.undo_checkin(APPT_IEN)

    assert result[:success], result.inspect
    assert_equal [ clinic_appointment_lister_param(other_start, other_loc) ],
                 clinic_lister_calls.map { |c| c[:params].first }
  end

  def test_undo_checkin_does_not_read_field_309_when_the_preflight_refuses
    seed_appointment_preflight(APPT_IEN, checkin: "", resource: RESOURCE_IEN)

    RpmsRpc::Scheduling.undo_checkin(APPT_IEN)

    assert_empty clinic_lister_calls
  end

  def test_undo_checkin_returns_not_undone_when_check_in_time_is_still_set
    seed_undo_checkin_graph(post_checkin: START_FM)

    result = RpmsRpc::Scheduling.undo_checkin(APPT_IEN)

    assert_scheduling_failure(result, error: :not_undone)
    refute_nil result[:message]
  end

  def test_undo_checkin_returns_partial_when_bsdx_fails_but_bsdx_check_in_was_cleared
    seed_undo_checkin_graph(checkin_rpc: { error: CANCHKIN_ERR }, post_checkin: "")

    result = RpmsRpc::Scheduling.undo_checkin(APPT_IEN)

    assert_scheduling_failure(result, error: :partial)
    refute_nil result[:message]
    assert_match(/9002018\.4|BSDX|check.?in/i, result[:message])
    assert_match(/clinic|#44|appointment check.?in/i, result[:message], result[:message])
    assert_equal 1, bsdx_checkin_calls.length
    gets_params = ddr_gets_calls.map { |c| c[:params].first }
    assert_equal 1, gets_params.count(appointment_post_checkin_gets_param(APPT_IEN)),
                 "expected one post-failure re-read of #9002018.4 field .03"
  end

  def test_undo_checkin_returns_the_bsdx_error_when_check_in_time_is_still_set_after_failure
    seed_undo_checkin_graph(checkin_rpc: { error: CANCHKIN_ERR }, post_checkin: START_FM)

    result = RpmsRpc::Scheduling.undo_checkin(APPT_IEN)

    refute result[:success]
    assert_equal CANCHKIN_ERR, result[:error]
    assert_equal 1, bsdx_checkin_calls.length
  end

  def test_undo_checkin_returns_lookup_failed_when_post_failure_re_read_of_check_in_fails
    seed_appointment_preflight(APPT_IEN, checkin: START_FM, resource: RESOURCE_IEN)
    seed_resource_hospital_loc(RESOURCE_IEN, HOSPITAL_LOC)
    RpmsRpc.client.seed(:scheduling_checkin_appointment, APPT_IEN.to_s, { error: CANCHKIN_ERR })
    seed_gets(file: "9002018.4", iens: "#{APPT_IEN},", fields: ".03", text: "[ERROR]")

    result = RpmsRpc::Scheduling.undo_checkin(APPT_IEN)

    assert_scheduling_failure(result, error: :lookup_failed)
    assert_equal 1, bsdx_checkin_calls.length
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
