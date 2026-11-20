# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc"
require "rpms_rpc/api/patient_application"
require_relative "../captured_replies"

# PATIENT APPLICATIONS (#9000045) through DDR LISTER and DDR FILER inside
# AG's edit lock (rpms-ux S-REG-03.3 to 03.5, openrpms#1053). The replies are
# the conversations PatientApplication had with the pinned build as
# PROFILE,REG on synthetic seed patient DFN 990010
# (test/fixtures/captured_replies/patient-application.yml, spec
# tools/captured_replies/patient-application.rb), replayed through CiaClient.
# Each test checks the gem sent exactly the recorded calls. The round trip
# itself is test/live/patient_application_live_test.rb.
class PatientApplicationTest < Minitest::Test
  PA = RpmsRpc::PatientApplication
  FM = RpmsRpc::FilemanDateParser
  SLUG = "patient-application"
  DFN = 990_010
  NONE_DFN = 990_011
  TYPE = 1
  DUZ = 207
  OBTAINED = Date.new(2026, 11, 10)
  SUBMITTED = Date.new(2026, 11, 11)
  LATER = Date.new(2026, 11, 12)

  def teardown
    RpmsRpc.reset!
  end

  def replay(flow)
    @flow = flow
    @client = CapturedReplies::ReplayCiaClient.new(flow ? CapturedReplies.flow_script(SLUG, flow) : {}).signed_on_as(DUZ)
    RpmsRpc.configure { |cfg| cfg.client = @client }
    @client
  end

  def sent = @client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params] ] }
  def rpcs = sent.map(&:first)
  def assert_sent_as_recorded = assert_equal(CapturedReplies.flow_calls(SLUG, @flow), sent, @flow)
  def filer_rows = sent.select { |rpc, _| rpc == "DDR FILER" }.map { |_, params| params[1].values }
  def fm(day) = FM.to_fileman(day)

  # The server's today in the recorded flow: its ORWU DT NOW reply.
  def server_today
    now = CapturedReplies.flow(SLUG, @flow).find { |c| c["rpc"] == "ORWU DT" }.fetch("raw_return")
    FM.parse_date(now.b.byteslice(2..).to_s[/\d{7}/])
  end

  def test_the_application_types_are_read_by_name
    replay("types")

    assert_includes PA.types, { ien: TYPE, name: "MEDICAID FORM 100" }
    assert_sent_as_recorded
  end

  def test_a_patient_with_no_entry_has_no_applications
    replay("none")

    assert_equal [], PA.for_patient(NONE_DFN)
    assert_sent_as_recorded
  end

  def test_s_reg_03_3_a_first_application_adds_the_patient_entry_the_application_its_submission_and_the_stamp
    replay("add_first")

    result = PA.add(DFN, obtained: OBTAINED, type: TYPE, submitted: SUBMITTED, via: "O", received_by: DUZ)

    assert result[:success], result.inspect
    assert_kind_of Integer, result[:application]
    assert_kind_of Integer, result[:submission]
    assert_sent_as_recorded
    today = fm(server_today)
    assert_equal [ "9000045^.01^+1,^#{DFN}",
                   "9000045.11^.01^+2,+1,^#{fm(OBTAINED)}", "9000045.11^.02^+2,+1,^#{TYPE}",
                   "9000045.11^.03^+2,+1,^#{DUZ}", "9000045.11^.04^+2,+1,^P",
                   "9000045.1101^.01^+3,+2,+1,^#{fm(SUBMITTED)}", "9000045.1101^.02^+3,+2,+1,^O",
                   "9000001^.03^#{DFN},^#{today}", "9000001^.12^#{DFN},^#{DUZ}", "9000001^.16^#{DFN},^#{today}" ],
                 filer_rows.first
    assert_equal [ "ORWU DT", "AGG LOCK PATIENT" ], rpcs.first(2)
    assert_equal "AGG UNLOCK PATIENT", rpcs.last
  end

  def test_s_reg_03_3_a_later_application_files_under_the_patients_existing_entry
    replay("add_later")

    result = PA.add(DFN, obtained: LATER, type: TYPE)

    assert result[:success], result.inspect
    assert_nil result[:submission]
    assert_sent_as_recorded
    assert_match(/\A9000045\.11\^\.01\^\+2,\d+,\^#{fm(LATER)}\z/, filer_rows.first.first.to_s)
  end

  def test_s_reg_03_3_an_application_already_on_file_on_that_date_is_not_added_again
    replay("add_exists")

    result = PA.add(DFN, obtained: OBTAINED, type: TYPE)

    assert_equal :exists, result[:error]
    assert_kind_of Integer, result[:application]
    refute_includes rpcs, "DDR FILER"
    assert_sent_as_recorded
  end

  def test_s_reg_03_3_a_type_not_on_file_is_refused_and_nothing_is_filed
    replay("add_type_missing")

    assert_equal :invalid, PA.add(DFN, obtained: LATER, type: 999)[:error]
    refute_includes rpcs, "DDR FILER"
    assert_equal "AGG UNLOCK PATIENT", rpcs.last
    assert_sent_as_recorded
  end

  def test_s_reg_03_3_what_fileman_would_refuse_is_refused_before_anything_is_sent
    replay("add_invalid")

    assert_equal :invalid, PA.add(DFN, obtained: Date.new(2027, 1, 1), type: TYPE)[:error]
    assert_equal :invalid, PA.add(DFN, obtained: OBTAINED, type: TYPE, status: "X")[:error]
    assert_equal :invalid, PA.add(DFN, obtained: OBTAINED, type: TYPE, via: "O")[:error]
    assert_equal :invalid, PA.add(DFN, obtained: OBTAINED, type: TYPE, submitted: SUBMITTED, reason: "AB")[:error]
    assert_equal :invalid, PA.add(DFN, obtained: OBTAINED, type: TYPE, submitted: SUBMITTED, reason: "A^B C")[:error]
    assert_equal [ "ORWU DT" ], rpcs, "only the server's date is read"
    assert_sent_as_recorded
  end

  def test_a_held_lock_sends_no_ddr_call
    replay("add_lock_held")

    assert_equal :lock_failed, PA.add(DFN, obtained: LATER, type: TYPE)[:error]
    refute(rpcs.any? { |rpc| rpc.start_with?("DDR") })
    assert_sent_as_recorded
  end

  def test_s_reg_03_4_an_outcome_files_the_overall_status_and_a_dated_status_under_the_latest_submission
    replay("status_approved")
    app = CapturedReplies.flow_calls(SLUG, "status_approved").find { |rpc, _| rpc == "DDR FILER" }.last[1].values.first
    application = app.to_s.split("^")[2].to_i

    assert_equal({ success: true, dated: true }, PA.update_status(DFN, application: application, status: "A"))
    assert_sent_as_recorded
    rows = filer_rows.first.map(&:to_s)
    assert_match(/\A9000045\.11\^\.04\^#{application},\d+,\^A\z/, rows[0])
    assert_match(/\A9000045\.110101\^\.01\^\+1,\d+,#{application},\d+,\^#{fm(server_today)}\z/, rows[1])
  end

  def test_s_reg_03_5_entered_in_error_is_a_status_and_nothing_is_deleted
    replay("status_error")
    app = CapturedReplies.flow_calls(SLUG, "status_error").find { |rpc, _| rpc == "DDR FILER" }.last[1].values.first
    application = app.to_s.split("^")[2].to_i

    assert PA.update_status(DFN, application: application, status: "E")[:success]
    assert_sent_as_recorded
    assert_match(/\A9000045\.11\^\.04\^#{application},\d+,\^E\z/, filer_rows.first.first.to_s)
    refute(filer_rows.first.any? { |r| r.to_s.end_with?("^@") })
  end

  def test_an_outcome_for_an_application_the_patient_does_not_have_is_not_found
    replay("status_not_found")

    assert_equal :not_found, PA.update_status(DFN, application: 999, status: "A")[:error]
    refute_includes rpcs, "DDR FILER"
    assert_sent_as_recorded
  end

  def test_s_reg_03_3_the_patients_applications_are_read_whole
    replay("applications")

    apps = PA.for_patient(DFN)

    assert_sent_as_recorded
    first = apps.find { |a| a[:obtained] == OBTAINED }
    assert_equal({ ien: TYPE, name: "MEDICAID FORM 100" }, first[:type])
    assert_equal [ "A", "APPROVED", DUZ ], first.values_at(:status, :status_name, :received_by)
    sub = first[:submissions].first
    assert_equal [ SUBMITTED, "O" ], sub.values_at(:date, :via)
    assert_equal [ "A" ], sub[:statuses].map { |s| s[:status] }
    assert_equal [ LATER, OBTAINED ], apps.map { |a| a[:obtained] }, "newest first"
  end
end
