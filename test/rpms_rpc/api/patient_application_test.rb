# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/agg"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/patient_application"

# Hermetic tests for PATIENT APPLICATIONS (#9000045) through DDR LISTER and
# DDR FILER inside AG's edit lock (rpms-ux S-REG-03.3 to 03.5, openrpms#1053).
class PatientApplicationTest < Minitest::Test
  PA = RpmsRpc::PatientApplication
  Ddr = RpmsRpc::DdrFileman
  FM = RpmsRpc::FilemanDateParser
  LOCK_OK = "I00010RESULT^T00080MESSAGE\x1e1^\x1e\x1f"
  LOCK_HELD = "I00010RESULT^T00080MESSAGE\x1e0^Held by DEMO,USER.\x1e\x1f"
  DFN = 990_010
  HEADER = 7
  APP = 3
  TYPE = 1
  OBTAINED = Date.today - 3
  SUBMITTED = Date.today - 2

  def setup
    @mock = RpmsRpc.mock!
    @mock.set_authenticated("501")
  end

  def teardown
    RpmsRpc.reset!
  end

  def rpcs = @mock.received_calls.map { |c| c[:rpc] }
  def filer_calls = @mock.received_calls.select { |c| c[:rpc] == "DDR FILER" }
  def filer_rows = one(filer_calls)[:params][1].values
  def fm(day) = FM.to_fileman(day)

  def one(list)
    assert_equal 1, list.size, list.inspect
    list.first
  end

  def seed_lock(reply = LOCK_OK)
    @mock.seed(:agg_lock_patient, DFN.to_s, reply)
    @mock.seed(:agg_unlock_patient, DFN.to_s, LOCK_OK)
  end

  def seed_lister(text, **param)
    @mock.seed(:ddr_lister, Ddr.lister_param(**param).to_s, text)
  end

  def seed_header(found)
    body = found ? "#{HEADER}^#{DFN}" : ""
    seed_lister("[Data]\n#{body}", file: "9000045", fields: "@;.01I", flags: "IP", xref: "B",
                                   from: (DFN - 1).to_s, max: PA::HEADER_B_MAX)
  end

  def seed_applications(rows)
    seed_lister("[Data]\n#{rows.join("\n")}", file: "9000045.11", iens: ",#{HEADER},",
                                               fields: "@;.01I;.02I;.02E;.03I;.04I;.05I", flags: "IP")
  end

  def seed_submissions(rows)
    seed_lister("[Data]\n#{rows.join("\n")}", file: "9000045.1101", iens: ",#{APP},#{HEADER},",
                                               fields: "@;.01I", flags: "IP")
  end

  def seed_type(found: true)
    key = Ddr.gets_entry_param(file: "9000048", iens: "#{TYPE},", fields: ".01", flags: "I").to_s
    @mock.seed(:ddr_gets_entry_data, key, found ? "[Data]\n9000048^#{TYPE},^.01^MEDICAID FORM 100^" : "[ERROR]")
  end

  def stamp_rows
    today = fm(Date.today)
    [ "9000001^.03^#{DFN},^#{today}", "9000001^.12^#{DFN},^501", "9000001^.16^#{DFN},^#{today}" ]
  end

  def test_s_reg_03_3_a_first_application_adds_the_patient_entry_the_application_its_submission_and_the_stamp
    seed_lock
    seed_type
    seed_header(false)
    @mock.seed(:ddr_filer, "ADD", "[Data]\n+1,^#{HEADER}\n+2,^1\n+3,^1")

    result = PA.add(DFN, obtained: OBTAINED, type: TYPE, submitted: SUBMITTED, via: "O", received_by: 501)

    assert_equal({ success: true, application: 1, submission: 1 }, result)
    assert_equal [ "9000045^.01^+1,^#{DFN}",
                   "9000045.11^.01^+2,+1,^#{fm(OBTAINED)}", "9000045.11^.02^+2,+1,^#{TYPE}",
                   "9000045.11^.03^+2,+1,^501", "9000045.11^.04^+2,+1,^P",
                   "9000045.1101^.01^+3,+2,+1,^#{fm(SUBMITTED)}", "9000045.1101^.02^+3,+2,+1,^O",
                   *stamp_rows ], filer_rows
    assert_equal "AGG LOCK PATIENT", rpcs.first
    assert_equal "AGG UNLOCK PATIENT", rpcs.last
  end

  def test_s_reg_03_3_a_later_application_files_under_the_patients_existing_entry
    seed_lock
    seed_type
    seed_header(true)
    seed_applications([ "#{APP}^#{fm(OBTAINED - 30)}^#{TYPE}^MEDICAID FORM 100^^P^" ])
    @mock.seed(:ddr_filer, "ADD", "[Data]\n+2,^4")

    assert_equal({ success: true, application: 4, submission: nil }, PA.add(DFN, obtained: OBTAINED, type: TYPE))
    assert_equal "9000045.11^.01^+2,#{HEADER},^#{fm(OBTAINED)}", filer_rows.first
  end

  def test_s_reg_03_3_an_application_already_on_file_on_that_date_is_not_added_again
    seed_lock
    seed_type
    seed_header(true)
    seed_applications([ "#{APP}^#{fm(OBTAINED)}^#{TYPE}^MEDICAID FORM 100^^P^" ])

    result = PA.add(DFN, obtained: OBTAINED, type: TYPE)

    assert_equal :exists, result[:error]
    assert_equal APP, result[:application]
    assert_empty filer_calls
  end

  def test_s_reg_03_3_a_type_not_on_file_is_refused_and_nothing_is_filed
    seed_lock
    seed_type(found: false)

    assert_equal :invalid, PA.add(DFN, obtained: OBTAINED, type: TYPE)[:error]
    assert_empty filer_calls
    assert_equal "AGG UNLOCK PATIENT", rpcs.last
  end

  def test_s_reg_03_3_a_failed_read_of_the_patient_entry_files_nothing
    seed_lock
    seed_type
    seed_lister("[Errors]", file: "9000045", fields: "@;.01I", flags: "IP", xref: "B", from: (DFN - 1).to_s,
                            max: PA::HEADER_B_MAX)

    assert_equal :lookup_failed, PA.add(DFN, obtained: OBTAINED, type: TYPE)[:error]
    assert_empty filer_calls
  end

  def test_s_reg_03_3_what_fileman_would_refuse_is_refused_before_anything_is_sent
    assert_equal :invalid, PA.add(DFN, obtained: Date.today + 1, type: TYPE)[:error]
    assert_equal :invalid, PA.add(DFN, obtained: OBTAINED, type: TYPE, status: "X")[:error]
    assert_equal :invalid, PA.add(DFN, obtained: OBTAINED, type: TYPE, via: "O")[:error]
    assert_equal :invalid, PA.add(DFN, obtained: OBTAINED, type: TYPE, submitted: SUBMITTED, reason: "AB")[:error]
    assert_equal :invalid, PA.add(DFN, obtained: OBTAINED, type: TYPE, submitted: SUBMITTED, reason: "A^B C")[:error]
    assert_empty rpcs
  end

  def test_a_held_lock_sends_no_ddr_call
    seed_lock(LOCK_HELD)

    assert_equal :lock_failed, PA.add(DFN, obtained: OBTAINED, type: TYPE)[:error]
    refute(rpcs.any? { |rpc| rpc.start_with?("DDR") })
  end

  def test_s_reg_03_4_an_outcome_files_the_overall_status_and_a_dated_status_under_the_latest_submission
    seed_lock
    seed_header(true)
    seed_applications([ "#{APP}^#{fm(OBTAINED)}^#{TYPE}^MEDICAID FORM 100^^P^" ])
    seed_submissions([ "1^#{fm(SUBMITTED - 5)}", "2^#{fm(SUBMITTED)}" ])
    @mock.seed(:ddr_filer, "ADD", "[Data]\n+1,^1")

    assert_equal({ success: true, dated: true }, PA.update_status(DFN, application: APP, status: "A", date: Date.today))
    assert_equal [ "9000045.11^.04^#{APP},#{HEADER},^A",
                   "9000045.110101^.01^+1,2,#{APP},#{HEADER},^#{fm(Date.today)}",
                   "9000045.110101^.02^+1,2,#{APP},#{HEADER},^A", *stamp_rows ], filer_rows
  end

  def test_s_reg_03_5_entered_in_error_is_a_status_and_nothing_is_deleted
    seed_lock
    seed_header(true)
    seed_applications([ "#{APP}^#{fm(OBTAINED)}^#{TYPE}^MEDICAID FORM 100^^P^" ])
    seed_submissions([])
    @mock.seed(:ddr_filer, "ADD", "[Data]")

    assert_equal({ success: true, dated: false }, PA.update_status(DFN, application: APP, status: "E"))
    assert_equal "9000045.11^.04^#{APP},#{HEADER},^E", filer_rows.first
    refute(filer_rows.any? { |r| r.end_with?("^@") })
  end

  def test_an_outcome_for_an_application_the_patient_does_not_have_is_not_found
    seed_lock
    seed_header(true)
    seed_applications([])

    assert_equal :not_found, PA.update_status(DFN, application: APP, status: "A")[:error]
    assert_empty filer_calls
  end

  def test_s_reg_03_3_the_patients_applications_are_read_whole
    seed_header(true)
    seed_applications([ "#{APP}^#{fm(OBTAINED)}^#{TYPE}^MEDICAID FORM 100^501^A^" ])
    seed_lister("[Data]\n2^#{fm(SUBMITTED)}^O^501^BY MAIL^AND PHONE", file: "9000045.1101",
                                                                      iens: ",#{APP},#{HEADER},",
                                                                      fields: "@;.01I;.02I;.04I;.03", flags: "IP")
    seed_lister("[Data]\n1^#{fm(Date.today)}^A", file: "9000045.110101", iens: ",2,#{APP},#{HEADER},",
                                                  fields: "@;.01I;.02I", flags: "IP")

    app = one(PA.for_patient(DFN))

    assert_equal({ ien: TYPE, name: "MEDICAID FORM 100" }, app[:type])
    assert_equal [ OBTAINED, "A", "APPROVED", 501 ], app.values_at(:obtained, :status, :status_name, :received_by)
    sub = one(app[:submissions])
    assert_equal [ SUBMITTED, "O", "BY MAIL^AND PHONE" ], sub.values_at(:date, :via, :reason)
    assert_equal [ { ien: 1, date: Date.today, status: "A" } ], sub[:statuses]
  end

  def test_a_failed_read_raises_rather_than_reading_as_no_applications
    seed_lister("[Errors]", file: "9000045", fields: "@;.01I", flags: "IP", xref: "B", from: (DFN - 1).to_s,
                            max: PA::HEADER_B_MAX)

    assert_raises(RpmsRpc::Client::RpcError) { PA.for_patient(DFN) }
  end

  def test_a_patient_with_no_entry_has_no_applications
    seed_header(false)

    assert_equal [], PA.for_patient(DFN)
  end
end
