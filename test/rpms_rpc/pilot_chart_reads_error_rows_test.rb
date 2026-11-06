# frozen_string_literal: true

require "minitest/autorun"
require_relative "pilot_chart_reads_test"

# Issue #512 round 5–6: caret-bearing error / sentinel rows must not count as record evidence
# (see CARET_CONTAINING_NON_RECORD_LIVE_CAPTURE_ROWS in pilot_chart_reads_test.rb).
class RpmsRpc::PilotChartReadsErrorRowsTest < Minitest::Test
  Grader = RpmsRpc::PilotChartReadsTest

  SYNTHETIC_RECORD_ROW_COMMA_PLUS_IN_NARRATIVE =
    "123^Diabetes, type 2 w/ neuropathy + CKD^A^E11.9^3200101^3250301^NSC^^^*^^10".freeze

  SYNTHETIC_RECORD_ROW_LOCATION_LIKE_NARRATIVE =
    "123^HTN stage 2, CKD + 3 x daily^A^I10^3200101^3250301^NSC^^^^^^".freeze

  # Narratives that end in WORD+digits before a one-letter status piece look like a
  # LABEL+off^ROUTINE location to a loose pattern; they are records.
  SYNTHETIC_RECORD_ROWS_PLUS_DIGITS_BEFORE_STATUS_PIECE = [
    "7^HIV+1^A^B20^3200101^3250301^NSC^^^^^^",
    "3^ANEMIA B12+1^A^D51.9^3200101^3250301^NSC^^^^^^",
    "5^GRADE 3+2^A^I10^3200101^3250301^NSC^^^^^^"
  ].freeze

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

  # Round 6 (#512): M-location / YDB stack text in a later piece must not satisfy record_row?.
  def test_m_location_stack_line_rows_are_not_record_rows
    failures = []
    Grader::M_LOCATION_STACK_LINE_LIVE_CAPTURE_ROWS.each do |error_row|
      next unless Grader.record_row?(error_row)

      failures << "#{error_row.inspect}: record_row? must be false"
    end
    assert_empty failures, failures.join("\n  ")
  end

  def test_m_location_stack_line_rows_grade_not_proven_on_fields_kind_slices
    failures = []
    Grader::M_LOCATION_STACK_LINE_LIVE_CAPTURE_ROWS.each do |error_row|
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

  def test_iris_gtm_m_error_rows_are_not_record_rows
    failures = []
    Grader::IRIS_GTM_M_ERROR_LIVE_CAPTURE_ROWS.each do |error_row|
      next unless Grader.record_row?(error_row)

      failures << "#{error_row.inspect}: record_row? must be false"
    end
    assert_empty failures, failures.join("\n  ")
  end

  def test_iris_gtm_m_error_rows_grade_not_proven_on_fields_kind_slices
    failures = []
    Grader::IRIS_GTM_M_ERROR_LIVE_CAPTURE_ROWS.each do |error_row|
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

  def test_empty_head_non_positive_piece_one_rows_are_not_record_rows
    failures = []
    Grader::EMPTY_HEAD_NON_POSITIVE_PIECE_ONE_LIVE_CAPTURE_ROWS.each do |error_row|
      next unless Grader.record_row?(error_row)

      failures << "#{error_row.inspect}: record_row? must be false"
    end
    assert_empty failures, failures.join("\n  ")
  end

  def test_empty_head_non_positive_piece_one_rows_grade_not_proven_on_fields_kind_slices
    failures = []
    Grader::EMPTY_HEAD_NON_POSITIVE_PIECE_ONE_LIVE_CAPTURE_ROWS.each do |error_row|
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

  def test_synthetic_record_row_with_comma_and_plus_in_narrative_counts_as_record_evidence
    row = SYNTHETIC_RECORD_ROW_COMMA_PLUS_IN_NARRATIVE
    assert Grader.record_row?(row),
           "narrative comma/plus must not be treated as M-location error text"

    stub = live_capture_stub(:problem_list, [ row ])
    slice = slice_for(:problem_list)
    mapping = RpmsRpc::DataMapper[:problem_list]
    all_readiness = Grader.readiness_attribute_names(mapping, stub)
    unproven = Grader.unproven_attributes(stub)
    refute_equal all_readiness.sort, unproven.sort,
                 "record row must prove at least one readiness field"
    refute_equal "not-proven", Grader.expected_checklist_status(slice, stub),
                 "single synthetic record row must not grade not-proven"
  end

  def test_synthetic_record_rows_with_plus_digits_before_a_status_piece_count_as_record_evidence
    SYNTHETIC_RECORD_ROWS_PLUS_DIGITS_BEFORE_STATUS_PIECE.each do |row|
      assert Grader.record_row?(row),
             "#{row.inspect}: WORD+digits before a one-letter status piece is a narrative, not a location"
    end
  end

  def test_synthetic_record_row_with_location_like_narrative_counts_as_record_evidence
    row = SYNTHETIC_RECORD_ROW_LOCATION_LIKE_NARRATIVE
    assert Grader.record_row?(row),
           "narrative digits/comma/plus must not be treated as LABEL+off^ROUTINE error text"

    stub = live_capture_stub(:problem_list, [ row ])
    slice = slice_for(:problem_list)
    mapping = RpmsRpc::DataMapper[:problem_list]
    all_readiness = Grader.readiness_attribute_names(mapping, stub)
    unproven = Grader.unproven_attributes(stub)
    refute_equal all_readiness.sort, unproven.sort,
                 "record row must prove at least one readiness field"
    refute_equal "not-proven", Grader.expected_checklist_status(slice, stub),
                 "single synthetic record row must not grade not-proven"
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
