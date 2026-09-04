# frozen_string_literal: true

require "minitest/autorun"
require "digest"
require "rpms_rpc/wire_capture"
require "rpms_rpc/mappings"

# Unit coverage for the wire-capture fixture model + contract checker
# (lib/rpms_rpc/wire_capture.rb, issue #189). The CI gate itself — every
# committed fixture checked against its registered mapping — lives in
# wire_contract_test.rb.
class RpmsRpc::WireCaptureTest < Minitest::Test
  RAW = "17^TMP^3260901.1436^98.6\n18^BP^3260901.1436^120/80"

  def live_fixture(overrides = {})
    data = {
      "rpc" => "ORQQVI VITALS",
      "mapping" => "vitals",
      "kind" => "fields",
      "source" => "live-capture",
      "cite" => "VITALS^ORQQVI (ORQQVI.m:4-24)",
      "release_tag" => "bcer-9.0-ydb",
      "captured_at" => "2026-09-02T00:00:00Z",
      "inputs" => [ "8", "2900101", "3991231" ],
      "raw_return" => RAW,
      "sha256" => Digest::SHA256.hexdigest(RAW),
      "pieces" => [
        { "position" => 0, "attribute" => "measurement_ien", "fileman_type" => "integer" },
        { "position" => 1, "attribute" => "type" },
        { "position" => 2, "attributes" => [ "recorded_date", "recorded_datetime" ],
          "fileman_type" => "fileman_datetime" },
        { "position" => 3, "attributes" => [ "value", "rate" ] }
      ]
    }.merge(overrides)
    overrides.each_key { |k| data.delete(k) if overrides[k].nil? }
    RpmsRpc::WireCapture::Fixture.new(data)
  end

  # -- provenance validation -------------------------------------------------

  def test_valid_live_capture_fixture_loads
    fx = live_fixture
    assert_equal "ORQQVI VITALS", fx.rpc
    assert_equal :vitals, fx.mapping_name
    assert_equal 2, fx.captured_rows.size
  end

  def test_fixture_without_recognized_source_is_rejected
    error = assert_raises(RpmsRpc::WireCapture::InvalidFixture) do
      live_fixture("source" => "hand-written")
    end
    assert_match(/without capture provenance is rejected/, error.message)
  end

  def test_live_capture_without_sha256_is_rejected
    assert_raises(RpmsRpc::WireCapture::InvalidFixture) { live_fixture("sha256" => nil) }
  end

  def test_live_capture_with_edited_raw_is_rejected
    error = assert_raises(RpmsRpc::WireCapture::InvalidFixture) do
      live_fixture("raw_return" => RAW + "\n99^HT^3260901.1436^60")
    end
    assert_match(/raw was edited after capture/, error.message)
  end

  def test_fixture_without_cite_is_rejected
    assert_raises(RpmsRpc::WireCapture::InvalidFixture) { live_fixture("cite" => nil) }
  end

  def test_routine_cite_fixture_must_not_claim_raw_return
    error = assert_raises(RpmsRpc::WireCapture::InvalidFixture) do
      live_fixture("source" => "routine-cite")
    end
    assert_match(/must not carry raw_return/, error.message)
  end

  def test_routine_cite_fixture_loads_with_example_return_only
    fx = live_fixture("source" => "routine-cite", "raw_return" => nil, "sha256" => nil,
                      "example_return" => "1^234")
    assert_equal [ "1^234" ], fx.rows
    assert_empty fx.captured_rows, "example rows are illustrative, never evidence"
  end

  def test_fields_fixture_requires_piece_annotations
    assert_raises(RpmsRpc::WireCapture::InvalidFixture) { live_fixture("pieces" => []) }
  end

  # -- contract checking -----------------------------------------------------

  def test_correct_mapping_passes_the_contract
    violations = RpmsRpc::WireCapture::Contract.check(RpmsRpc::DataMapper[:vitals], live_fixture)
    assert_empty violations, violations.join("; ")
  end

  def test_attribute_mismatch_is_flagged
    mapping = RpmsRpc::DataMapper::Mapping.new(:wrong)
    mapping.configure do
      rpc "ORQQVI VITALS"
      field 0, :type
    end

    violations = RpmsRpc::WireCapture::Contract.check(mapping, live_fixture)
    assert_equal [ :attribute_mismatch ], violations.map(&:kind)
    assert_equal 0, violations.first.position
    assert_includes violations.first.expected, "measurement_ien"
  end

  def test_field_beyond_the_captured_layout_is_flagged
    mapping = RpmsRpc::DataMapper::Mapping.new(:wrong)
    mapping.configure do
      rpc "ORQQVI VITALS"
      field 9, :units
    end

    violations = RpmsRpc::WireCapture::Contract.check(mapping, live_fixture)
    assert_equal [ :unannotated_position ], violations.map(&:kind)
  end

  def test_declared_type_is_validated_against_captured_raw_pieces
    mapping = RpmsRpc::DataMapper::Mapping.new(:wrong)
    mapping.configure do
      rpc "ORQQVI VITALS"
      field 3, :value, :fileman_date # raw pieces are "98.6" / "120/80"
    end

    violations = RpmsRpc::WireCapture::Contract.check(mapping, live_fixture)
    # :value is a legitimate name for position 3, so no attribute mismatch —
    # but the captured raw pieces ("98.6", "120/80") cannot be FileMan dates.
    assert_equal [ :type_mismatch, :type_mismatch ], violations.map(&:kind)
    assert_equal [ "98.6", "120/80" ], violations.map(&:detail)
  end

  def test_empty_raw_pieces_do_not_fail_type_validation
    # The "^No vitals found." sentinel (ORQQVI.m:24) leaves typed positions
    # empty — emptiness is not a type violation.
    raw = "^No vitals found."
    fx = live_fixture("raw_return" => raw, "sha256" => Digest::SHA256.hexdigest(raw))
    violations = RpmsRpc::WireCapture::Contract.check(RpmsRpc::DataMapper[:vitals], fx)
    assert_empty violations, violations.join("; ")
  end

  def test_rpc_mismatch_is_flagged
    violations = RpmsRpc::WireCapture::Contract.check(RpmsRpc::DataMapper[:patient_select],
                                                      live_fixture)
    assert_equal [ :rpc_mismatch ], violations.map(&:kind)
  end

  def test_kind_mismatch_is_flagged
    mapping = RpmsRpc::DataMapper::Mapping.new(:wrong)
    mapping.configure do
      rpc "ORQQVI VITALS"
      scalar :everything
    end

    violations = RpmsRpc::WireCapture::Contract.check(mapping, live_fixture)
    assert_equal [ :kind_mismatch ], violations.map(&:kind)
  end

  # -- catalog sanity --------------------------------------------------------

  def test_catalog_entries_bind_to_registered_mappings
    RpmsRpc::WireCapture::CATALOG.each do |entry|
      mapping = RpmsRpc::DataMapper[entry.mapping]
      assert_equal entry.rpc, mapping.rpc_name,
                   "catalog entry #{entry.rpc} must bind the mapping that declares that RPC"
    end
  end

  def test_catalog_never_marks_a_write_rpc_live
    add_patient = RpmsRpc::WireCapture::CATALOG.find { |e| e.rpc == "VAFC VOA ADD PATIENT" }
    refute_nil add_patient
    refute add_patient.live?, "VAFC VOA ADD PATIENT writes — capture must stay routine-cite"
  end
end
