# frozen_string_literal: true

require "minitest/autorun"
require "set"
require "rpms_rpc/conformance/delta"
require "rpms_rpc/conformance/reader"

class RpmsRpc::Conformance::DeltaTest < Minitest::Test
  FIXTURES_DIR = File.expand_path("../../../data/fingerprints", __dir__)

  def fingerprint(release: nil, rpc_names: [])
    RpmsRpc::Conformance::Fingerprint.from_h(
      "release" => release,
      "rpcs" => rpc_names.to_h { |name| [name, {}] }
    )
  end

  def test_missing_is_required_minus_target_sorted
    target = fingerprint(rpc_names: %w[B A])
    required = fingerprint(release: "bcer-8.0", rpc_names: %w[C A D])

    delta = RpmsRpc::Conformance::Delta.between(target: target, required: required)

    assert_equal %w[C D], delta[:missing]
    assert_equal %w[B], delta[:extra]
  end

  def test_required_may_be_a_set_or_array_of_names
    target = fingerprint(rpc_names: %w[A B])

    from_set = RpmsRpc::Conformance::Delta.between(target: target, required: Set["A", "C"])
    from_array = RpmsRpc::Conformance::Delta.between(target: target, required: %w[A C])

    assert_equal %w[C], from_set[:missing]
    assert_equal from_set, from_array
  end

  def test_conformant_target_has_empty_missing
    target = fingerprint(rpc_names: %w[A B C])
    required = fingerprint(release: "bcer-5.0", rpc_names: %w[A B])

    delta = RpmsRpc::Conformance::Delta.between(target: target, required: required)

    assert_empty delta[:missing]
    assert_equal %w[C], delta[:extra]
  end

  def test_empty_sets_produce_empty_deltas
    delta = RpmsRpc::Conformance::Delta.between(target: fingerprint, required: fingerprint)

    assert_equal({ missing: [], extra: [] }, delta)
  end

  # Integration: probing the committed staging fingerprint against the
  # bcer-8.0 seed reference must reproduce a subset of the 87 known
  # gem-only misses recorded on 2026-06-07 (.gem_only_misses_20260607.txt).
  def test_staging_probe_reproduces_known_gem_misses
    staging = RpmsRpc::Conformance::FixtureReader.new(
      File.join(FIXTURES_DIR, "staging-2026-06-07.yml")
    ).fingerprint
    required = RpmsRpc::Conformance::FixtureReader.new(
      File.join(FIXTURES_DIR, "references", "bcer-8.0.yml")
    ).fingerprint

    delta = RpmsRpc::Conformance::Delta.between(target: staging, required: required)

    known_misses = [
      "GMTS PWH REPORT", "PSO ERX STATUS", "BPHR PATIENT DIRECT",
      "XU KEY LIST", "ORWU USERKEYS", "ORWLRR RESULT LIST",
      "ORWRA REPORT", "ORWPCE IMPLANT LIST", "ORWRP TYPES",
      "XQAL NEW ALERTS"
    ]
    known_misses.each do |rpc|
      assert_includes delta[:missing], rpc
    end

    # Present-on-staging namespaces must NOT be reported missing.
    ["ORWPT SELECT", "ORQQPL DETAIL", "ORWLRR INTERIM", "XQAL GUI ALERTS"].each do |rpc|
      refute_includes delta[:missing], rpc
    end
  end
end
