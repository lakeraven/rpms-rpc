# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/vital"

class VitalTest < Minitest::Test
  def setup
    RpmsRpc.mock! do |m|
      # Template: BEHOVM TEMPLATE — multi-line field metadata, keyed by location IEN
      m.seed_keyed_collection(:vital_template, "349", [
        { ien: 3,  display_order: 3,  name: "TEMPERATURE",  abbreviation: "TMP", units: "F",     low: nil, high: nil, percentile_rpc: nil,            required: 1, display_row: 2 },
        { ien: 5,  display_order: 5,  name: "PULSE",        abbreviation: "PU",  units: "/min",  low: 60,  high: 100, percentile_rpc: nil,            required: 1, display_row: 2 },
        { ien: 4,  display_order: 4,  name: "BLOOD PRESSURE", abbreviation: "BP", units: "mmHg", low: 90,  high: 150, percentile_rpc: nil,            required: 1, display_row: 2 },
        { ien: 1,  display_order: 1,  name: "HEIGHT",       abbreviation: "HT",  units: "in",    low: nil, high: nil, percentile_rpc: "BEHOVM PCTILE", required: 1, display_row: 2 },
        { ien: 2,  display_order: 2,  name: "WEIGHT",       abbreviation: "WT",  units: "lb",    low: nil, high: nil, percentile_rpc: "BEHOVM PCTILE", required: 1, display_row: 3 }
      ])

      # Validate: BEHOVM VALIDATE — scalar, keyed by "abbrev|value"; echoes value on success.
      m.seed_scalar(:vital_validate, "TMP|97",   "97")
      m.seed_scalar(:vital_validate, "PU|80",    "80")
      m.seed_scalar(:vital_validate, "BP|130/90", "130/90")
      m.seed_scalar(:vital_validate, "TMP|999",  "INVALID")
      m.seed_scalar(:vital_validate, "PU|10",    "INVALID")

      # Save: BEHOVM SAVE — "0" success per observed trace
      m.seed_scalar(:vital_save, "8791", "0")
      m.seed_scalar(:vital_save, "9999", "1^bad request")
    end
  end

  def teardown
    RpmsRpc.reset!
  end

  def test_for_patient_still_works
    assert_kind_of Array, RpmsRpc::Vital.for_patient("1")
  end

  # === template ===

  def test_template_returns_field_metadata_for_location
    fields = RpmsRpc::Vital.template(349)
    assert_kind_of Array, fields
    assert_equal 5, fields.length
    tmp = fields.find { |f| f[:abbreviation] == "TMP" }
    assert_equal "TEMPERATURE", tmp[:name]
    bp = fields.find { |f| f[:abbreviation] == "BP" }
    assert_equal 90,  bp[:low]
    assert_equal 150, bp[:high]
  end

  def test_template_returns_empty_for_unknown_location
    assert_equal [], RpmsRpc::Vital.template(999999)
  end

  # === validate(dfn, measurements) — per issue #61 contract ===

  def test_validate_returns_valid_true_for_all_valid_measurements
    result = RpmsRpc::Vital.validate(8791, [
      { abbreviation: "TMP", value: 97 },
      { abbreviation: "PU",  value: 80 },
      { abbreviation: "BP",  value: "130/90" }
    ])
    assert result[:valid], "Expected valid; got #{result.inspect}"
    assert_empty result[:errors]
  end

  def test_validate_returns_field_level_errors_with_index_and_abbreviation
    result = RpmsRpc::Vital.validate(8791, [
      { abbreviation: "TMP", value: 97 },
      { abbreviation: "TMP", value: 999 },
      { abbreviation: "PU",  value: 10 }
    ])
    refute result[:valid]
    assert_equal 2, result[:errors].length
    first = result[:errors].first
    assert_equal 1,     first[:index]
    assert_equal "TMP", first[:abbreviation]
    assert_equal 999,   first[:value]
    assert_match(/Validation failed/, first[:error_message])
  end

  def test_validate_handles_empty_measurement_list
    result = RpmsRpc::Vital.validate(8791, [])
    assert result[:valid]
    assert_empty result[:errors]
  end

  def test_validate_forwards_dfn_to_underlying_rpc
    RpmsRpc::Vital.validate(8791, [ { abbreviation: "TMP", value: 97 } ])
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BEHOVM VALIDATE" }
    refute_nil call, "Expected BEHOVM VALIDATE to fire"
    assert_includes call[:params], "8791", "DFN should be forwarded to RPC"
  end

  # === add(dfn, visit_string, measurements, provider_duz:) ===

  def test_add_returns_success_for_bulk_save
    measurements = [
      { abbreviation: "TMP", value: 97,        units: "F" },
      { abbreviation: "PU",  value: 80,        units: "/min" },
      { abbreviation: "BP",  value: "130/90",  units: "mmHg" }
    ]
    result = RpmsRpc::Vital.add(8791, "492;3260514.09;A;2090059", measurements, provider_duz: 2843)
    assert result[:success], "Expected success; got #{result.inspect}"
    assert_equal 3, result[:measurement_count]
    assert_equal "0", result[:raw].to_s
  end

  def test_add_sends_payload_with_visit_dfn_and_measurements
    measurements = [
      { abbreviation: "TMP", value: 97, units: "F" },
      { abbreviation: "PU",  value: 80, units: "/min" }
    ]
    RpmsRpc::Vital.add(8791, "492;3260514.09;A;2090059", measurements, provider_duz: 2843)

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BEHOVM SAVE" }
    refute_nil call, "Expected BEHOVM SAVE to fire"
    assert_equal "8791", call[:params][0].to_s, "param[0] should be DFN"

    payload = call[:params][1]
    refute_nil payload, "param[1] should be the multi-line save payload"
    payload_text = payload.join("\n")
    assert_match(/HDR\^\^\^492;3260514\.09;A;2090059/, payload_text, "HDR line should carry visit string")
    assert_match(/VST\^PT\^8791/, payload_text, "VST PT line should carry DFN")
    assert_match(/VIT\+\^TMP\^0\^\^97\^2843\^F\^/, payload_text, "VIT+ TMP line should carry value + units + provider DUZ")
    assert_match(/VIT\+\^PU\^0\^\^80\^2843\^\/min\^/, payload_text, "VIT+ PU line should carry value + units + provider DUZ")
  end

  def test_add_returns_failure_for_empty_measurement_set
    result = RpmsRpc::Vital.add(8791, "v", [], provider_duz: 2843)
    refute result[:success]
    assert_equal 0, result[:measurement_count]
    assert_equal "EMPTY", result[:raw]
  end

  def test_add_returns_failure_when_save_returns_nonzero
    result = RpmsRpc::Vital.add(9999, "v", [ { abbreviation: "TMP", value: 97, units: "F" } ], provider_duz: 2843)
    refute result[:success]
    assert_equal "1^bad request", result[:raw]
  end

  # === build_save_payload (public for testability) ===

  def test_build_save_payload_uses_provider_duz_in_vit_lines
    payload = RpmsRpc::Vital.build_save_payload(8791, "v1", [ { abbreviation: "TMP", value: 97, units: "F" } ], provider_duz: 2843)
    assert payload.any? { |line| line.include?("^2843^") }, "VIT+ line should embed provider DUZ"
  end

  # === provider_duz is required per issue #61 contract ===

  def test_add_raises_argument_error_when_provider_duz_is_missing
    measurements = [ { abbreviation: "TMP", value: 97, units: "F" } ]
    error = assert_raises(ArgumentError) do
      RpmsRpc::Vital.add(8791, "v1", measurements)
    end
    assert_match(/provider_duz/, error.message)
  end

  def test_add_raises_argument_error_when_provider_duz_is_nil
    measurements = [ { abbreviation: "TMP", value: 97, units: "F" } ]
    error = assert_raises(ArgumentError) do
      RpmsRpc::Vital.add(8791, "v1", measurements, provider_duz: nil)
    end
    assert_match(/provider_duz is required/, error.message)
  end

  # provider_duz check fires BEFORE the empty-measurements early return,
  # so missing provider with an empty list still raises rather than
  # silently returning a (vacuous) "empty" result.
  def test_add_raises_for_nil_provider_duz_even_with_empty_measurements
    assert_raises(ArgumentError) do
      RpmsRpc::Vital.add(8791, "v1", [], provider_duz: nil)
    end
  end

  def test_build_save_payload_raises_for_nil_provider_duz
    measurements = [ { abbreviation: "TMP", value: 97, units: "F" } ]
    assert_raises(ArgumentError) do
      RpmsRpc::Vital.build_save_payload(8791, "v1", measurements, provider_duz: nil)
    end
  end

  # === Measurement coercion (no accidental Array(hash) flattening) ===

  def test_add_accepts_a_single_measurement_hash_without_flattening
    measurement = { abbreviation: "TMP", value: 97, units: "F" }
    result = RpmsRpc::Vital.add(8791, "492;3260514.09;A;2090059", measurement, provider_duz: 2843)
    assert result[:success]
    assert_equal 1, result[:measurement_count]
    # The VIT+ line must contain TMP / 97 / F, not Array(hash) pair tokens.
    payload_text = result[:payload].join("\n")
    assert_match(/VIT\+\^TMP\^0\^\^97\^2843\^F\^/, payload_text)
  end

  def test_add_treats_nil_measurements_as_empty
    result = RpmsRpc::Vital.add(8791, "v1", nil, provider_duz: 2843)
    refute result[:success]
    assert_equal "EMPTY", result[:raw]
  end
end
