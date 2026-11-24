# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/vital"
require_relative "../captured_replies"

# Vital.add over BEHOVM SAVE, SAVE(DATA,DFN,VITS) (BEHOVM.m:389). The replies
# are the build's (test/fixtures/captured_replies/behovm-save.yml): add run as
# PROFILE,MD on a throwaway container, on a visit filed for synthetic DFN
# 990054, recorded as flows and replayed through CiaClient. Each test that
# reaches the wire checks the gem sent exactly the recorded call. The filing
# itself is proven live by test/live/vital_add_taken_at_live_test.rb.
class VitalTest < Minitest::Test
  SLUG = "behovm-save"
  # When the measurements were taken, as the capture gave it. add without
  # taken_at reads the server's clock (ORWU DT), which the live spec proves
  # (rpms-rpc#741).
  TAKEN = Time.new(2026, 11, 19, 9, 30, 15)
  DFN = 990_054
  # The visit string the capture filed on, as the gem sent it.
  VISIT = CapturedReplies.flow_calls(SLUG, "add").first.dig(1, 1, 0).delete_prefix("HDR^^^")

  def setup
    replay
  end

  def teardown
    RpmsRpc.reset!
  end

  # A client with no replies unless a flow is named: a test that reaches
  # the wire without one fails.
  def replay(script = {})
    @client = CapturedReplies::ReplayCiaClient.new(script)
    RpmsRpc.configure { |cfg| cfg.client = @client }
  end

  def replay_flow(name) = replay(CapturedReplies.flow_script(SLUG, name))

  def sent = @client.calls.map { |c| [ c[:rpc], c[:params] ] }

  # === template ===

  VSTR = "349;3260514.09;A;2090059"

  # Template rows are proven against the build in test/live/vital_reads_live_test.rb.

  def test_template_returns_empty_without_a_visit_string_or_patient
    assert_equal [], RpmsRpc::Vital.template(8791, "")
    assert_equal [], RpmsRpc::Vital.template(nil, VSTR)
    assert_empty @client.calls
  end

  # validate is tested against the build's replies in vital_validate_test.rb.

  # === add(dfn, visit_string, measurements, provider_duz:) ===

  THREE = [
    { abbreviation: "TMP", value: 97,       units: "F" },
    { abbreviation: "PU",  value: 80,       units: "/min" },
    { abbreviation: "BP",  value: "130/90", units: "mmHg" }
  ].freeze

  def test_add_returns_success_for_bulk_save
    replay_flow("add")
    result = RpmsRpc::Vital.add(DFN, VISIT, THREE, provider_duz: 206, taken_at: TAKEN)
    assert result[:success], "Expected success; got #{result.inspect}"
    assert_equal 3, result[:measurement_count]
    assert_equal "0", result[:raw].to_s
  end

  def test_add_sends_payload_with_visit_dfn_and_measurements
    replay_flow("add")
    RpmsRpc::Vital.add(DFN, VISIT, THREE, provider_duz: 206, taken_at: TAKEN)

    assert_equal CapturedReplies.flow_calls(SLUG, "add"), sent
    dfn, payload = sent.first.last
    assert_equal DFN.to_s, dfn, "param[0] should be DFN"
    assert_equal "HDR^^^#{VISIT}", payload.first, "HDR line should carry visit string"
    assert_includes payload, "VST^PT^#{DFN}"
    assert_includes payload, "VIT+^TMP^0^^97^206^F^^3261119.093015^^"
    assert_includes payload, "VIT+^PU^0^^80^206^/min^^3261119.093015^^"
  end

  def test_add_returns_failure_for_empty_measurement_set
    result = RpmsRpc::Vital.add(8791, "v", [], provider_duz: 2843)
    refute result[:success]
    assert_equal 0, result[:measurement_count]
    assert_equal "EMPTY", result[:raw]
  end

  # The build refuses a value out of range and stores none of the set.
  def test_add_returns_failure_when_save_returns_nonzero
    replay_flow("add_refused")
    result = RpmsRpc::Vital.add(DFN, VISIT, [ { abbreviation: "TMP", value: 999, units: "F" } ], provider_duz: 206, taken_at: TAKEN)
    refute result[:success]
    assert_equal 1, result[:measurement_count]
    assert_equal "-1^1  entry failed validation.  No results stored.", result[:raw]
    assert_equal CapturedReplies.flow_calls(SLUG, "add_refused"), sent
  end

  # === build_save_payload (public for testability) ===

  def test_build_save_payload_stamps_the_time_the_caller_gives
    # 21:30 on Nov 15 at the site is already Nov 16 in UTC; the site's time is filed.
    taken = Time.new(2026, 11, 15, 21, 30, 5, "-08:00")
    payload = RpmsRpc::Vital.build_save_payload(8791, "v1", [ { abbreviation: "TMP", value: 97, units: "F" } ], provider_duz: 2843, taken_at: taken)

    assert_equal "VST^DT^3261115.213005", payload[1]
    assert_equal "VIT+^TMP^0^^97^2843^F^^3261115.213005^^", payload.last
  end

  def test_build_save_payload_uses_provider_duz_in_vit_lines
    payload = RpmsRpc::Vital.build_save_payload(8791, "v1", [ { abbreviation: "TMP", value: 97, units: "F" } ], provider_duz: 2843, taken_at: TAKEN)
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
      RpmsRpc::Vital.build_save_payload(8791, "v1", measurements, provider_duz: nil, taken_at: TAKEN)
    end
  end

  # === Measurement coercion (no accidental Array(hash) flattening) ===

  def test_add_accepts_a_single_measurement_hash_without_flattening
    replay_flow("add_one")
    measurement = { abbreviation: "TMP", value: 98, units: "F" }
    result = RpmsRpc::Vital.add(DFN, VISIT, measurement, provider_duz: 206, taken_at: TAKEN)
    assert result[:success]
    assert_equal 1, result[:measurement_count]
    # The VIT+ line must contain TMP / 98 / F, not Array(hash) pair tokens.
    assert_equal CapturedReplies.flow_calls(SLUG, "add_one"), sent
    assert_equal "VIT+^TMP^0^^98^206^F^^3261119.093015^^", result[:payload].last
  end

  def test_add_treats_nil_measurements_as_empty
    result = RpmsRpc::Vital.add(8791, "v1", nil, provider_duz: 2843)
    refute result[:success]
    assert_equal "EMPTY", result[:raw]
  end
end
