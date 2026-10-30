# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/wire_capture"
require_relative "orwpce_read_helpers"

# Issue #286: wire shapes for ORWPCE read RPCs, proven against unmapped
# capture bytes (promoted to test/fixtures/wire_captures/ + CATALOG by the builder).
class OrwpceReadWireTest < Minitest::Test
  include OrwpceReadHelpers

  def test_promoted_captures_have_catalog_entries_for_each_in_scope_rpc
    missing = IN_SCOPE_RPCS.reject do |rpc|
      RpmsRpc::WireCapture::CATALOG.any? { |entry| entry.rpc == rpc }
    end
    assert_empty missing,
                 "each promoted ORWPCE read needs a WireCapture::CATALOG entry:\n#{missing.join("\n")}"
  end

  def test_promoted_captures_live_beside_other_wire_contract_fixtures
    missing = IN_SCOPE_RPCS.reject do |rpc|
      File.file?(File.join(PROMOTED_DIR, CAPTURE_BASENAME.call(rpc)))
    end
    assert_empty missing,
                 "each promoted ORWPCE read needs test/fixtures/wire_captures/#{CAPTURE_BASENAME.call('…')}:\n" \
                 "#{missing.map { |rpc| CAPTURE_BASENAME.call(rpc) }.join("\n")}"
  end

  OrwpceReadHelpers::RPC_TO_MAPPING.each do |rpc, mapping_name|
    define_method("test_catalog_entry_for_#{mapping_name}_binds_#{rpc.tr(' ', '_')}") do
      entry = RpmsRpc::WireCapture::CATALOG.find { |e| e.rpc == rpc }
      refute_nil entry, "missing CATALOG entry for #{rpc}"
      assert_equal mapping_name, entry.mapping,
                   "CATALOG entry for #{rpc} must bind :#{mapping_name}"
    end
  end

  # -- ORWPCE GET VISIT (scalar visit IEN) -----------------------------------

  def test_get_visit_capture_rows_parse_to_visit_ien_or_nil
    mapping = mapping_for("ORWPCE GET VISIT")
    load_unmapped_capture("ORWPCE GET VISIT").fetch("captures").each do |cap|
      body = cia_data_body(cap.fetch("raw_return"))
      visit_ien = mapping.parse_scalar(body)
      case body.strip
      when "-1", ""
        assert_nil visit_ien, cap.fetch("context")
      else
        assert_operator visit_ien.to_i, :>, 0, cap.fetch("context")
      end
    end
  end

  # -- ORWPCE HASVISIT -------------------------------------------------------

  def test_hasvisit_capture_minus_one_is_not_found
    mapping = mapping_for("ORWPCE HASVISIT")
    cap = load_unmapped_capture("ORWPCE HASVISIT").fetch("captures").find do |c|
      c.fetch("context").include?("none found")
    end
    refute_nil cap
    assert_nil mapping.parse_scalar(cia_data_body(cap.fetch("raw_return")))
  end

  def test_hasvisit_capture_zero_means_visit_exists
    mapping = mapping_for("ORWPCE HASVISIT")
    load_unmapped_capture("ORWPCE HASVISIT").fetch("captures").each do |cap|
      next if cia_data_body(cap.fetch("raw_return")).strip == "-1"

      assert_equal true, mapping.parse_scalar(cia_data_body(cap.fetch("raw_return"))),
                   cap.fetch("context")
    end
  end

  # -- ORWPCE NOTEVSTR -------------------------------------------------------

  def test_notevstr_capture_parses_loc_datetime_service
    mapping = mapping_for("ORWPCE NOTEVSTR")
    expected = [
      { location_ien: 3, datetime_raw: "3260902.0255", service_category: "A" },
      { location_ien: 7, datetime_raw: "3260904.2344", service_category: "T" }
    ]
    load_unmapped_capture("ORWPCE NOTEVSTR").fetch("captures").zip(expected).each do |cap, exp|
      row = mapping.parse_visit_string(cia_data_body(cap.fetch("raw_return")))
      assert_equal exp, row, cap.fetch("context")
    end
  end

  def test_notevstr_empty_body_parses_as_none
    mapping = mapping_for("ORWPCE NOTEVSTR")
    assert_nil mapping.parse_visit_string("")
  end

  def test_skin_test_type_capture_rows_are_ien_and_name
    mapping = mapping_for("ORWPCE GET SKIN TEST TYPE")
    lines = cia_data_lines(load_unmapped_capture("ORWPCE GET SKIN TEST TYPE").fetch("captures").first.fetch("raw_return"))
    rows = mapping.parse_many(lines)
    assert_equal(
      [ { ien: "2", name: "PPD" }, { ien: "6", name: "TETANUS" } ],
      rows.map { |r| { ien: r[:ien].to_s, name: r[:name] } }
    )
  end

  def test_skin_test_type_trailing_empty_line_yields_no_row
    mapping = mapping_for("ORWPCE GET SKIN TEST TYPE")
    lines = cia_data_lines(load_unmapped_capture("ORWPCE GET SKIN TEST TYPE").fetch("captures").first.fetch("raw_return")) + [ "" ]
    assert_equal 2, mapping.parse_many(lines).size
  end

  def test_exam_type_capture_includes_foot_inspection_row
    mapping = mapping_for("ORWPCE GET EXAM TYPE")
    lines = cia_data_lines(load_unmapped_capture("ORWPCE GET EXAM TYPE").fetch("captures").first.fetch("raw_return"))
    row = mapping.parse_many(lines).find { |r| r[:ien].to_s == "28" }
    refute_nil row
    assert_equal "FOOT INSPECTION", row[:name]
  end

  def test_immunization_type_capture_rows_are_ien_and_name
    mapping = mapping_for("ORWPCE GET IMMUNIZATION TYPE")
    lines = cia_data_lines(load_unmapped_capture("ORWPCE GET IMMUNIZATION TYPE").fetch("captures").first.fetch("raw_return"))
    row = mapping.parse_many(lines).find { |r| r[:ien].to_s == "272" }
    refute_nil row
    assert_includes row[:name], "Influenza, adjuvanted, trivalent"
  end

  def test_education_topic_capture_rows_are_ien_and_name
    mapping = mapping_for("ORWPCE GET EDUCATION TOPICS")
    lines = cia_data_lines(load_unmapped_capture("ORWPCE GET EDUCATION TOPICS").fetch("captures").first.fetch("raw_return"))
    row = mapping.parse_many(lines).find { |r| r[:ien].to_s == "5991" }
    refute_nil row
    assert_equal "ABD-ANATOMY AND PHYSIOLOGY", row[:name]
  end

  def test_health_factor_type_without_addcats_is_ien_and_name_only
    mapping = mapping_for("ORWPCE GET HEALTH FACTORS TY")
    cap = load_unmapped_capture("ORWPCE GET HEALTH FACTORS TY").fetch("captures").first
    lines = cia_data_lines(cap.fetch("raw_return"))
    row = mapping.parse_many(lines).find { |r| r[:ien].to_s == "25" }
    refute_nil row
    assert_equal "0-FOOD AND EXERCISE", row[:name]
    assert_nil row[:category]
    assert_nil row[:category_ien]
  end

  def test_health_factor_type_with_addcats_includes_category_pieces
    mapping = mapping_for("ORWPCE GET HEALTH FACTORS TY")
    cap = load_unmapped_capture("ORWPCE GET HEALTH FACTORS TY").fetch("captures").last
    lines = cia_data_lines(cap.fetch("raw_return"))
    row = mapping.parse_many(lines).find { |r| r[:ien].to_s == "25" }
    refute_nil row
    assert_equal "F", row[:category]
    assert_equal "24", row[:category_ien].to_s
  end

  # -- ORWPCE PCE4NOTE -------------------------------------------------------
  #
  # Unknown record types are kept on the bundle as opaque entries (record_type +
  # raw line) so forward-compatible hosts can log them without treating them as
  # modeled clinical data.

  def test_pce4note_rich_capture_exposes_modeled_record_types_and_fields
    cap = load_unmapped_capture("ORWPCE PCE4NOTE").fetch("captures").first
    bundle = mapping_for("ORWPCE PCE4NOTE").parse_note_bundle(cia_data_lines(cap.fetch("raw_return")))

    assert_equal "3;3260902.0255;A", bundle.dig(:header, :visit_string)
    assert_equal 4, bundle.dig(:header, :visit_ien)

    pov = bundle.fetch(:diagnoses).find { |r| r[:icd_code] == "J20.9" }
    refute_nil pov
    assert_includes pov[:narrative], "Acute bronchitis"

    assert_equal 2, bundle.fetch(:immunizations).size
    assert bundle.fetch(:patient_education).any? { |r| r[:topic_ien].to_s == "1611" }
    assert bundle.fetch(:exams).any? { |r| r[:exam_ien].to_s == "28" && r[:name] == "FOOT INSPECTION" }
  end

  def test_pce4note_provider_only_capture_carries_chart_review_location
    cap = load_unmapped_capture("ORWPCE PCE4NOTE").fetch("captures")[1]
    bundle = mapping_for("ORWPCE PCE4NOTE").parse_note_bundle(cia_data_lines(cap.fetch("raw_return")))

    assert_equal "7;3260904.2344;T", bundle.dig(:header, :visit_string)
    assert_equal 1, bundle.fetch(:providers).size
    assert_equal "MANAGER,SYSTEM", bundle.fetch(:providers).first[:name]
    assert_equal "CHART REVIEW", bundle.dig(:visit, :hospital_location_name)
  end

  def test_pce4note_header_only_capture_has_no_clinical_rows
    cap = load_unmapped_capture("ORWPCE PCE4NOTE").fetch("captures").last
    bundle = mapping_for("ORWPCE PCE4NOTE").parse_note_bundle(cia_data_lines(cap.fetch("raw_return")))

    assert_equal "6;3260312.09;A", bundle.dig(:header, :visit_string)
    assert_empty bundle.fetch(:diagnoses)
    assert_empty bundle.fetch(:providers)
  end

  def test_pce4note_keeps_unknown_record_types_as_opaque_entries
    cap = load_unmapped_capture("ORWPCE PCE4NOTE").fetch("captures").first
    lines = cia_data_lines(cap.fetch("raw_return")) + [ "ZZZ^1^2^synthetic" ]
    bundle = mapping_for("ORWPCE PCE4NOTE").parse_note_bundle(lines)

    unknown = bundle.fetch(:opaque_records).find { |r| r[:record_type] == "ZZZ" }
    refute_nil unknown
    assert_equal "ZZZ^1^2^synthetic", unknown[:raw]
  end
end
