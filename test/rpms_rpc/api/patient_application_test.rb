# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc"
require "rpms_rpc/api/patient_application"
require_relative "../captured_replies"

# PATIENT APPLICATIONS (#9000045) through DDR LISTER and DDR FILER inside
# AG's edit lock (rpms-ux S-REG-03.3 to 03.5, openrpms#1053). The replies are
# the conversations PatientApplication had with the pinned build as
# PROFILE,REG (DUZ 207) on synthetic seed patient DFN 990010
# (test/fixtures/captured_replies/patient-application.yml, spec
# tools/captured_replies/patient-application.rb), replayed through
# CiaClient's own reply grammar. The server's clock (ORWU DT) read
# 11/20/2026 throughout. Each test checks the gem sent exactly the recorded
# calls. The round trip itself is test/live/patient_application_live_test.rb.
class PatientApplicationTest < Minitest::Test
  PA = RpmsRpc::PatientApplication
  SLUG = "patient-application"
  DFN = 990_010
  TYPE = 1 # MEDICAID FORM 100
  SERVER_TODAY = Date.new(2026, 11, 20)
  OBTAINED = Date.new(2026, 11, 1)
  SUBMITTED = Date.new(2026, 11, 2)
  EARLIER = Date.new(2026, 10, 1)
  STAMP = [ "9000001^.03^#{DFN},^3261120", "9000001^.12^#{DFN},^207", "9000001^.16^#{DFN},^3261120" ].freeze

  def teardown
    RpmsRpc.reset!
  end

  def replay(flow)
    @flow = flow
    @client = CapturedReplies::ReplayCiaClient.new(flow ? CapturedReplies.flow_script(SLUG, flow) : {}).signed_on_as(207)
    RpmsRpc.configure { |cfg| cfg.client = @client }
    @client
  end

  def sent = @client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params] ] }
  def rpcs = sent.map(&:first)
  def filer_rows = sent.select { |rpc, _| rpc == "DDR FILER" }.map { |_, params| params[1].values }
  def assert_sent_as_recorded = assert_equal(CapturedReplies.flow_calls(SLUG, @flow), sent, @flow)

  def test_s_reg_03_3_a_first_application_adds_the_patient_entry_the_application_its_submission_and_the_stamp
    replay("add_first")

    result = PA.add(DFN, obtained: OBTAINED, type: TYPE, submitted: SUBMITTED, via: "O", received_by: 207)

    assert_equal({ success: true, application: 1, submission: 1 }, result)
    assert_sent_as_recorded
    assert_equal [ [ "9000045^.01^+1,^#{DFN}",
                     "9000045.11^.01^+2,+1,^3261101", "9000045.11^.02^+2,+1,^#{TYPE}",
                     "9000045.11^.03^+2,+1,^207", "9000045.11^.04^+2,+1,^P",
                     "9000045.1101^.01^+3,+2,+1,^3261102", "9000045.1101^.02^+3,+2,+1,^O",
                     *STAMP ] ], filer_rows
    assert_equal [ "ORWU DT", "AGG LOCK PATIENT" ], rpcs.first(2)
    assert_equal "AGG UNLOCK PATIENT", rpcs.last
  end

  def test_s_reg_03_3_a_later_application_files_under_the_patients_existing_entry
    replay("add_later")

    assert_equal({ success: true, application: 2, submission: nil }, PA.add(DFN, obtained: EARLIER, type: TYPE))
    assert_sent_as_recorded
    assert_equal "9000045.11^.01^+2,1,^3261001", filer_rows.first.first
  end

  def test_s_reg_03_3_an_application_already_on_file_on_that_date_is_not_added_again
    replay("add_exists")

    result = PA.add(DFN, obtained: OBTAINED, type: TYPE)

    assert_equal :exists, result[:error]
    assert_equal 1, result[:application]
    assert_sent_as_recorded
    refute_includes rpcs, "DDR FILER"
  end

  # GETS^DIQ answers [ERROR] for a type not on file.
  def test_s_reg_03_3_a_type_not_on_file_is_refused_and_nothing_is_filed
    replay("add_type_unknown")

    assert_equal :invalid, PA.add(DFN, obtained: OBTAINED, type: 999_999)[:error]
    assert_sent_as_recorded
    refute_includes rpcs, "DDR FILER"
    assert_equal "AGG UNLOCK PATIENT", rpcs.last
  end

  # "Today" and "the future" are the server's (rpms-rpc#741): the date guard
  # reads ORWU DT, which the capture's add_future flow recorded; the others
  # refuse before it.
  def test_s_reg_03_3_what_fileman_would_refuse_is_refused_before_anything_is_sent
    clock = CapturedReplies.raw(SLUG, "add_future/1")
    cases = [ { obtained: SERVER_TODAY + 1 }, { obtained: OBTAINED, status: "X" }, { obtained: OBTAINED, via: "O" },
              { obtained: OBTAINED, submitted: SUBMITTED, reason: "AB" },
              { obtained: OBTAINED, submitted: SUBMITTED, reason: "A^B C" } ]
    cases.each do |args|
      @client = CapturedReplies::ReplayCiaClient.new("ORWU DT" => [ clock ])
      RpmsRpc.configure { |cfg| cfg.client = @client }

      assert_equal :invalid, PA.add(DFN, type: TYPE, **args)[:error], args.inspect
      assert_empty rpcs - [ "ORWU DT" ], "#{args.inspect}: at most the server's date is read"
    end
    @client = CapturedReplies::ReplayCiaClient.new("ORWU DT" => [ clock ])
    RpmsRpc.configure { |cfg| cfg.client = @client }
    PA.add(DFN, obtained: SERVER_TODAY + 1, type: TYPE)
    assert_equal CapturedReplies.flow_calls(SLUG, "add_future"), sent, "a future date is judged on the server's clock"
  end

  def test_a_held_lock_sends_no_ddr_call
    replay("lock_held")

    assert_equal :lock_failed, PA.add(DFN, obtained: Date.new(2026, 9, 1), type: TYPE)[:error]
    assert_sent_as_recorded
    refute(rpcs.any? { |rpc| rpc.start_with?("DDR") })
  end

  def test_s_reg_03_4_an_outcome_files_the_overall_status_and_a_dated_status_under_the_latest_submission
    replay("status_approved")

    assert_equal({ success: true, dated: true }, PA.update_status(DFN, application: 1, status: "A"))
    assert_sent_as_recorded
    assert_equal [ [ "9000045.11^.04^1,1,^A",
                     "9000045.110101^.01^+1,1,1,1,^3261120",
                     "9000045.110101^.02^+1,1,1,1,^A", *STAMP ] ], filer_rows
  end

  def test_s_reg_03_5_entered_in_error_is_a_status_and_nothing_is_deleted
    replay("status_in_error")

    assert_equal({ success: true, dated: false }, PA.update_status(DFN, application: 2, status: "E"))
    assert_sent_as_recorded
    assert_equal "9000045.11^.04^2,1,^E", filer_rows.first.first
    refute(filer_rows.flatten.any? { |r| r.end_with?("^@") })
  end

  def test_an_outcome_for_an_application_the_patient_does_not_have_is_not_found
    replay("status_not_found")

    assert_equal :not_found, PA.update_status(DFN, application: 999, status: "A")[:error]
    assert_sent_as_recorded
    refute_includes rpcs, "DDR FILER"
  end

  def test_s_reg_03_3_the_patients_applications_are_read_whole
    replay("for_patient")

    apps = PA.for_patient(DFN)

    assert_equal [ 1, 2 ], apps.map { |a| a[:ien] }
    app = apps.find { |a| a[:ien] == 1 }
    assert_equal({ ien: TYPE, name: "MEDICAID FORM 100" }, app[:type])
    assert_equal [ OBTAINED, "A", "APPROVED", 207 ], app.values_at(:obtained, :status, :status_name, :received_by)
    assert_equal 1, app[:submissions].size
    sub = app[:submissions].first
    assert_equal [ SUBMITTED, "O" ], sub.values_at(:date, :via)
    assert_equal [ { ien: 1, date: SERVER_TODAY, status: "A" } ], sub[:statuses]
    assert_equal "E", apps.find { |a| a[:ien] == 2 }[:status], "an application in error stays on file"
    assert_sent_as_recorded
  end

  def test_a_patient_with_no_entry_has_no_applications
    replay("for_patient_none")

    assert_equal [], PA.for_patient(DFN)
    assert_sent_as_recorded
  end
end
