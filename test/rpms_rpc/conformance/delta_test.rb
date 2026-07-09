# frozen_string_literal: true

require "minitest/autorun"
require "set"
require "rpms_rpc/conformance/delta"
require "rpms_rpc/conformance/reader"

class RpmsRpc::Conformance::DeltaTest < Minitest::Test
  FIXTURES_DIR = File.expand_path("../../../data/fingerprints", __dir__)

  def fingerprint(release: nil, rpc_names: [], packages: {})
    RpmsRpc::Conformance::Fingerprint.from_h(
      "release" => release,
      "rpcs" => rpc_names.to_h { |name| [ name, {} ] },
      "packages" => packages
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

  def test_package_gaps_reports_absent_and_lower_versioned_packages_sorted
    target = fingerprint(packages: { "MAILMAN" => "8.0", "PHARMACY" => "6.0" })
    required = fingerprint(
      release: "bcer-8.0",
      packages: { "PHARMACY" => "7.0", "MAILMAN" => "8.0", "IHS STANDARD TERMINOLOGY" => "2.0" }
    )

    gaps = RpmsRpc::Conformance::Delta.package_gaps(target: target, required: required)

    assert_equal(
      {
        "IHS STANDARD TERMINOLOGY" => { required: "2.0", actual: nil },
        "PHARMACY" => { required: "7.0", actual: "6.0" }
      },
      gaps
    )
    assert_equal gaps.keys.sort, gaps.keys
  end

  def test_package_gaps_equal_or_higher_versions_are_not_gaps
    # Gem::Version semantics: "2" == "2.0", "8.1" > "8.0".
    target = fingerprint(packages: { "IHS KERNEL MENU OPTIONS" => "2.0", "MAILMAN" => "8.1" })
    required = fingerprint(packages: { "IHS KERNEL MENU OPTIONS" => "2", "MAILMAN" => "8.0" })

    assert_empty RpmsRpc::Conformance::Delta.package_gaps(target: target, required: required)
  end

  def test_package_gaps_unparseable_versions_fall_back_to_string_equality
    # ".5" (PATIENT MERGE in the wild) is not a valid Gem::Version; equal
    # strings satisfy, differing strings gap.
    same = fingerprint(packages: { "PATIENT MERGE" => ".5" })
    different = fingerprint(packages: { "PATIENT MERGE" => ".6" })
    required = fingerprint(packages: { "PATIENT MERGE" => ".5" })

    assert_empty RpmsRpc::Conformance::Delta.package_gaps(target: same, required: required)
    assert_equal(
      { "PATIENT MERGE" => { required: ".5", actual: ".6" } },
      RpmsRpc::Conformance::Delta.package_gaps(target: different, required: required)
    )
  end

  def test_package_gaps_versionless_requirement_is_satisfied_by_presence
    target = fingerprint(packages: { "UTILITIES" => "" })
    required = fingerprint(packages: { "UTILITIES" => "", "SITE MANAGEMENT" => "" })

    gaps = RpmsRpc::Conformance::Delta.package_gaps(target: target, required: required)

    assert_equal({ "SITE MANAGEMENT" => { required: "", actual: nil } }, gaps)
  end

  def test_package_gaps_versionless_target_cannot_satisfy_a_versioned_requirement
    target = fingerprint(packages: { "PHARMACY" => "" })
    required = fingerprint(packages: { "PHARMACY" => "7.0" })

    assert_equal(
      { "PHARMACY" => { required: "7.0", actual: "" } },
      RpmsRpc::Conformance::Delta.package_gaps(target: target, required: required)
    )
  end

  def test_package_gaps_required_may_be_a_plain_hash
    target = fingerprint(packages: { "MAILMAN" => "8.0" })

    gaps = RpmsRpc::Conformance::Delta.package_gaps(
      target: target, required: { "MAILMAN" => "8.0", "PHARMACY" => "7.0" }
    )

    assert_equal({ "PHARMACY" => { required: "7.0", actual: nil } }, gaps)
  end

  def test_package_gaps_empty_required_packages_produce_no_gaps
    target = fingerprint(packages: { "MAILMAN" => "8.0" })

    assert_empty RpmsRpc::Conformance::Delta.package_gaps(target: target, required: fingerprint)
  end

  def test_between_is_unchanged_by_package_faces
    target = fingerprint(rpc_names: %w[A], packages: { "MAILMAN" => "1.0" })
    required = fingerprint(rpc_names: %w[A B], packages: { "MAILMAN" => "8.0" })

    delta = RpmsRpc::Conformance::Delta.between(target: target, required: required)

    assert_equal({ missing: %w[B], extra: [] }, delta)
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
    [ "ORWPT SELECT", "ORQQPL DETAIL", "ORWLRR INTERIM", "XQAL GUI ALERTS" ].each do |rpc|
      refute_includes delta[:missing], rpc
    end
  end

  # Integration: the bcer-8.0 seed reference carries a SEED packages face;
  # the committed staging fingerprint has no packages captured, so every
  # seed package must surface as an absent gap.
  def test_staging_probe_reports_seed_reference_packages_as_gaps
    staging = RpmsRpc::Conformance::FixtureReader.new(
      File.join(FIXTURES_DIR, "staging-2026-06-07.yml")
    ).fingerprint
    required = RpmsRpc::Conformance::FixtureReader.new(
      File.join(FIXTURES_DIR, "references", "bcer-8.0.yml")
    ).fingerprint

    gaps = RpmsRpc::Conformance::Delta.package_gaps(target: staging, required: required)

    assert_equal required.package_versions.keys.sort, gaps.keys
    assert_equal({ required: "7.2", actual: nil }, gaps["IHS PATIENT REGISTRATION"])
  end
end
