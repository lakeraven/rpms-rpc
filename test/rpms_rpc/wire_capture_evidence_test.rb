# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/wire_capture"
require_relative "pilot_chart_reads_test"

# SPEC (#512): pilot chart-read grading must treat masked/pseudo wire tokens as
# unproven. Builder implements RpmsRpc::WireCapture::Evidence.real_value? and
# wires it into PilotChartReadsTest — these tests fail until then.
class RpmsRpc::WireCaptureEvidenceTest < Minitest::Test
  Grader = RpmsRpc::PilotChartReadsTest

  StubFixture = Struct.new(:mapping_name, :source, :captured_data_rows, :path, keyword_init: true)

  PSEUDO_ID_INFO_SSN_ROW =
    "602000000P **Pseudo SSN**^2850115^M^N^^^^DEMOPATIENT,REG2244"

  REAL_ID_INFO_SSN_ROW =
    "123456789^2850115^M^N^^^^DEMOPATIENT,REG2244"

  FULL_REAL_ID_INFO_ROW =
    "123456789^2850115^M^N^50^3E^301^DEMOPATIENT,REG2244"

  FULL_PSEUDO_ID_INFO_ROW =
    "602000000P **Pseudo SSN**^2850115^M^N^50^3E^301^DEMOPATIENT,REG2244"

  CHART_FIELD_MAPPINGS = Grader::CHART_READ_SLICE.filter_map do |slice|
    next if %i[patient_cwad medication_active].include?(slice[:mapping])

    slice[:mapping]
  end.freeze

  def id_info_slice
    Grader::CHART_READ_SLICE.find { |s| s[:mapping] == :patient_id_info }
  end

  def stub_fixture(mapping_name, rows, path: nil)
    StubFixture.new(
      mapping_name: mapping_name,
      source: "live-capture",
      captured_data_rows: Array(rows),
      path: path
    )
  end

  def non_boolean_mapped_attributes(mapping_name)
    mapping = RpmsRpc::DataMapper[mapping_name]
    boolean = Grader::BOOLEAN_MAPPED_ATTRIBUTES[mapping_name] || []
    Grader.mapped_attribute_names(mapping).reject { |attr| boolean.include?(attr) }
  end

  def all_pseudo_caret_row(mapping_name)
    mapping = RpmsRpc::DataMapper[mapping_name]
    max_piece = mapping.fields.map(&:position).max
    Array.new(max_piece + 1, "**Pseudo**").join("^")
  end

  def ptinfo_row(ssn:, mrn:, name: "USER,TEST", sex: "M", dob: "2850115", team: "TEAM", provider: "PROV,ONE")
    pieces = Array.new(18, "")
    pieces[0] = name
    pieces[1] = sex
    pieces[2] = dob
    pieces[3] = ssn
    pieces[10] = mrn
    pieces[16] = team
    pieces[17] = provider
    pieces.join("^")
  end

  # -- WireCapture::Evidence (module under test) --------------------------------

  def test_placeholder_patterns_constant_is_data_driven
    patterns = RpmsRpc::WireCapture::Evidence::PLACEHOLDER_PATTERNS
    assert patterns.frozen?, "PLACEHOLDER_PATTERNS must be frozen"
    refute_empty patterns
    assert patterns.all?(Regexp), "every PLACEHOLDER_PATTERNS entry must be a Regexp: #{patterns.inspect}"
  end

  def test_real_value_rejects_nil_like_and_masked_tokens
    ev = RpmsRpc::WireCapture::Evidence
    [
      nil, "", "   ", "XXX-XX-XXXX", "XXX-XX-1234", "xxx-xx-xxxx",
      "**Pseudo SSN**", "602000000P **Pseudo SSN**", "***", "000-00-0000",
      "---", "<none>"
    ].each do |value|
      refute ev.real_value?(value), "expected not real: #{value.inspect}"
    end
  end

  def test_real_value_accepts_ordinary_wire_tokens
    ev = RpmsRpc::WireCapture::Evidence
    [
      "123-45-6789", "602000000", "DEMOPATIENT,REG2244", "M", "N", "MRN123",
      "2850115", "123456789"
    ].each do |value|
      assert ev.real_value?(value), "expected real: #{value.inspect}"
    end
  end

  def test_real_value_treats_false_and_zero_as_real
    ev = RpmsRpc::WireCapture::Evidence
    assert ev.real_value?(false)
    assert ev.real_value?(0)
  end

  def test_real_value_arrays_are_real_iff_any_element_is_real
    ev = RpmsRpc::WireCapture::Evidence
    refute ev.real_value?([])
    refute ev.real_value?(["", "XXX-XX-XXXX"])
    assert ev.real_value?(["", "MRN123"])
  end

  # -- Grader: ORWPT ID INFO (gate repro) ---------------------------------------

  def test_patient_id_info_pseudo_ssn_row_lists_ssn_unproven
    fx = stub_fixture(:patient_id_info, PSEUDO_ID_INFO_SSN_ROW)
    unproven = Grader.unproven_attributes(fx)
    assert_includes unproven, :ssn,
                    "pseudo SSN token must not grade :ssn proven (gate M1 repro)"
  end

  def test_patient_id_info_real_ssn_piece_does_not_list_ssn_unproven
    fx = stub_fixture(:patient_id_info, REAL_ID_INFO_SSN_ROW)
    unproven = Grader.unproven_attributes(fx)
    refute_includes unproven, :ssn,
                    "real SSN-bearing PID must grade :ssn proven when present"
  end

  def test_patient_id_info_fully_populated_pseudo_ssn_is_partial_not_pilot_ready
    slice = id_info_slice
    fx = stub_fixture(:patient_id_info, FULL_PSEUDO_ID_INFO_ROW)
    status = Grader.expected_checklist_status(slice, fx)
    refute_equal "pilot-ready", status,
                 "masked/pseudo SSN must block pilot-ready even when other fields populate"
    assert_equal "partial", status
  end

  def test_patient_id_info_fully_populated_real_ssn_is_pilot_ready
    slice = id_info_slice
    fx = stub_fixture(:patient_id_info, FULL_REAL_ID_INFO_ROW)
    status = Grader.expected_checklist_status(slice, fx)
    assert_equal "pilot-ready", status,
                 "regression: an all-real ORWPT ID INFO row must still reach pilot-ready"
  end

  # -- Grader: BEHOPTCX PTINFO --------------------------------------------------

  def test_patient_ptinfo_masked_ssn_tokens_leave_ssn_unproven
    [
      ptinfo_row(ssn: "XXX-XX-1234", mrn: "MRN123"),
      ptinfo_row(ssn: "**Pseudo SSN**", mrn: "MRN123")
    ].each do |row|
      fx = stub_fixture(:patient_ptinfo, row, path: nil)
      unproven = Grader.unproven_attributes(fx)
      assert_includes unproven, :ssn,
                      "BEHOPTCX :ssn must stay unproven for #{row.split("^")[3].inspect}"
    end
  end

  def test_patient_ptinfo_placeholder_mrn_tokens_leave_mrn_unproven
    [
      ptinfo_row(ssn: "123-45-6789", mrn: "**N/A**"),
      ptinfo_row(ssn: "123-45-6789", mrn: "***")
    ].each do |row|
      fx = stub_fixture(:patient_ptinfo, row, path: nil)
      unproven = Grader.unproven_attributes(fx)
      assert_includes unproven, :mrn,
                      "placeholder MRN must not grade :mrn proven (#{row.split("^")[10].inspect})"
    end
  end

  def test_patient_ptinfo_real_mrn_grades_mrn_proven_without_fixture_persona
    row = ptinfo_row(ssn: "123-45-6789", mrn: "MRN123")
    fx = stub_fixture(:patient_ptinfo, row, path: nil)
    unproven = Grader.unproven_attributes(fx)
    refute_includes unproven, :mrn,
                    "real MRN on the wire must grade :mrn proven when path/signed_on_as is absent"
  end

  # -- Grader: generic placeholder sweep ----------------------------------------

  def test_every_chart_read_field_mapping_rejects_all_pseudo_pieces
    failures = []
    CHART_FIELD_MAPPINGS.each do |mapping_name|
      row = all_pseudo_caret_row(mapping_name)
      fx = stub_fixture(mapping_name, row, path: nil)
      unproven = Grader.unproven_attributes(fx)
      non_boolean_mapped_attributes(mapping_name).each do |attribute|
        next if unproven.include?(attribute)

        failures << ":#{mapping_name} :#{attribute} wrongly proven on all-**Pseudo** row"
      end
    end
    assert_empty failures, failures.join("\n  ")
  end

  # -- Regression: real row stays proven ----------------------------------------

  def test_patient_id_info_full_real_row_leaves_no_unproven_attributes
    fx = stub_fixture(:patient_id_info, FULL_REAL_ID_INFO_ROW)
    unproven = Grader.unproven_attributes(fx)
    assert_empty unproven,
                 "regression: fully populated real ID INFO must not mark everything unproven (#{unproven.inspect})"
  end
end
