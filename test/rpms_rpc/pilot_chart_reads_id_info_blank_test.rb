# frozen_string_literal: true

require "minitest/autorun"
require_relative "pilot_chart_reads_test"
require_relative "captured_replies"

# rpms-rpc#604 item 3 (dev-lead call 2026-11-09): an ORWPT ID INFO reply with
# both SSN and DOB blank grades not-proven, never partial. The rows are the
# pinned build's own replies (test/fixtures/captured_replies/orwpt-id-info.yml),
# read through CiaClient; demo patient 2, whose SSN alone is blank, is the
# positive control that the grader still grades a real row partial.
class RpmsRpc::PilotChartReadsIdInfoBlankTest < Minitest::Test
  Grader = RpmsRpc::PilotChartReadsTest
  SLUG = "orwpt-id-info"

  def captured_rows(name)
    client = CapturedReplies::ReplayCiaClient.new("ORWPT ID INFO" => [ CapturedReplies.raw(SLUG, name) ])
    client.call_rpc("ORWPT ID INFO", "x").to_a
  end

  def grade(name)
    stub = Struct.new(:mapping_name, :source, :captured_data_rows, :path)
                 .new(:patient_id_info, "live-capture", captured_rows(name), nil)
    slice = Grader::CHART_READ_SLICE.find { |entry| entry[:mapping] == :patient_id_info }
    [ Grader.expected_checklist_status(slice, stub), Grader.unproven_attributes(stub), stub ]
  end

  def test_a_reply_with_ssn_and_dob_both_blank_grades_not_proven
    assert_equal [ "^^^^^^^" ], captured_rows("no_such_patient")

    status, unproven, stub = grade("no_such_patient")
    assert_equal "not-proven", status, "blank SSN and DOB is no record: not-proven, never partial"
    mapping = RpmsRpc::DataMapper[:patient_id_info]
    assert_equal Grader.readiness_attribute_names(mapping, stub).sort, unproven.sort
  end

  def test_a_real_row_with_only_ssn_blank_still_grades_partial
    status, unproven = grade("blank_ssn")
    assert_equal "partial", status
    assert_includes unproven, :ssn
    refute_includes unproven, :dob
  end
end
