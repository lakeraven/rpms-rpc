# frozen_string_literal: true

require "minitest/autorun"
require_relative "pilot_chart_reads_test"

# Issue #512 round 5: caret-bearing error / sentinel rows must not count as record evidence
# (see CARET_CONTAINING_NON_RECORD_LIVE_CAPTURE_ROWS in pilot_chart_reads_test.rb).
class RpmsRpc::PilotChartReadsErrorRowsTest < Minitest::Test
  Grader = RpmsRpc::PilotChartReadsTest

  LIVE_CAPTURE_FIELDS_POSITIVE_CONTROL_STATUS = {
    patient_id_info: "partial",
    patient_ptinfo: "partial",
    problem_list: "partial",
    allergy_list: "partial",
    vitals: "partial"
  }.freeze

  class << self
    def live_capture_stub(mapping_name, rows)
      Struct.new(:mapping_name, :source, :captured_data_rows, :path).new(
        mapping_name, "live-capture", Array(rows), nil
      )
    end
  end

  def live_capture_stub(mapping_name, rows)
    self.class.live_capture_stub(mapping_name, rows)
  end

  def slice_for(mapping_name)
    Grader::CHART_READ_SLICE.find { |entry| entry[:mapping] == mapping_name }
  end

  # Same sweep shape as test_fields_kind_live_capture_non_record_rows_grade_not_proven (round 3).
  def test_fields_kind_caret_error_rows_grade_not_proven
    failures = []
    Grader::CARET_CONTAINING_NON_RECORD_LIVE_CAPTURE_ROWS.each do |error_row|
      Grader::CHART_FIELDS_READINESS_MAPPINGS.each do |mapping_name|
        stub = live_capture_stub(mapping_name, [ error_row ])
        mapping = RpmsRpc::DataMapper[mapping_name]
        slice = slice_for(mapping_name)
        all_readiness = Grader.readiness_attribute_names(mapping, stub).sort
        unproven = Grader.unproven_attributes(stub).sort
        if unproven != all_readiness
          failures << ":#{mapping_name} row #{error_row.inspect}: unproven #{unproven.inspect}, " \
                       "expected all #{all_readiness.inspect}"
        end
        status = Grader.expected_checklist_status(slice, stub)
        next if status == "not-proven"

        failures << ":#{mapping_name} row #{error_row.inspect}: status #{status.inspect}, expected not-proven"
      end
    end
    assert_empty failures, failures.join("\n  ")
  end

  def test_problem_list_mixed_valid_row_and_vista_error_does_not_add_proof
    path = Grader.fixture_path_for("ORQQPL LIST")
    skip "no ORQQPL LIST fixture" unless File.file?(path)

    valid_row = RpmsRpc::WireCapture::Fixture.load_file(path).captured_data_rows.first
    refute_nil valid_row, "committed ORQQPL LIST must include a record row"

    error_row = "0^No problems^^^^^^^^^^^"
    alone = live_capture_stub(:problem_list, [ valid_row ])
    mixed = live_capture_stub(:problem_list, [ valid_row, error_row ])

    alone_unproven = Grader.unproven_attributes(alone).sort
    mixed_unproven = Grader.unproven_attributes(mixed).sort
    assert_equal alone_unproven, mixed_unproven,
                 "Vista error row must not newly prove fields (alone #{alone_unproven.inspect}, " \
                 "mixed #{mixed_unproven.inspect})"

    assert_includes mixed_unproven, :inactive_icd,
                    "error row must not prove inactive_icd false when valid row alone does not"
  end

  # Positive controls: tightening record_row? must not demote committed live-capture grades.
  def test_committed_live_capture_fields_fixtures_remain_positive_controls
    failures = []
    LIVE_CAPTURE_FIELDS_POSITIVE_CONTROL_STATUS.each do |mapping_name, expected_status|
      slice = slice_for(mapping_name)
      path = Grader.fixture_path_for(slice[:rpc])
      unless File.file?(path)
        failures << ":#{mapping_name}: missing fixture #{path}"
        next
      end

      fixture = RpmsRpc::WireCapture::Fixture.load_file(path)
      unless fixture.source == "live-capture" && fixture.captured_data_rows.any?
        failures << ":#{mapping_name}: expected non-empty live-capture fixture"
        next
      end

      actual = Grader.expected_checklist_status(slice, fixture)
      next if actual == expected_status

      failures << ":#{mapping_name}: status #{actual.inspect}, expected committed grade #{expected_status.inspect}"
    end
    assert_empty failures, failures.join("\n  ")
  end
end
