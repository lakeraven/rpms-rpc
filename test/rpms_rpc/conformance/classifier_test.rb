# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/conformance/classifier"
require "rpms_rpc/conformance/reader"

class RpmsRpc::Conformance::ClassifierTest < Minitest::Test
  FIXTURES_DIR = File.expand_path("../../../data/fingerprints", __dir__)

  def fingerprint(release: nil, rpc_names: [], packages: {})
    RpmsRpc::Conformance::Fingerprint.from_h(
      "release" => release,
      "rpcs" => rpc_names.to_h { |name| [ name, {} ] },
      "packages" => packages
    )
  end

  def test_classifies_as_the_highest_coverage_reference
    old_rung = fingerprint(release: "bcer-5.0", rpc_names: %w[A B C D])
    new_rung = fingerprint(release: "bcer-8.0", rpc_names: %w[A B C D E F G H])
    target = fingerprint(rpc_names: %w[A B C D E])

    result = RpmsRpc::Conformance::Classifier.new(references: [ new_rung, old_rung ]).classify(target)

    assert_equal "bcer-5.0", result[:classified_as]
    assert_in_delta 1.0, result[:coverage]
    assert_equal %w[bcer-5.0 bcer-8.0], result[:ranked].map { |r| r[:release] }
    assert_in_delta 5.0 / 8, result[:ranked].last[:coverage]
  end

  def test_coverage_counts_only_reference_rpcs_present_on_target
    ref = fingerprint(release: "bcer-8.0", rpc_names: %w[A B C D])
    target = fingerprint(rpc_names: %w[A B X Y Z])

    result = RpmsRpc::Conformance::Classifier.new(references: [ ref ]).classify(target)

    assert_in_delta 0.5, result[:coverage]
  end

  def test_ties_break_by_smallest_symmetric_difference
    # Both rungs fully covered (coverage 1.0); the bigger rung shares more
    # of the target's surface (smaller symmetric difference), so it wins.
    small = fingerprint(release: "bcer-5.0", rpc_names: %w[A B])
    large = fingerprint(release: "bcer-7.0", rpc_names: %w[A B C D])
    target = fingerprint(rpc_names: %w[A B C D E])

    result = RpmsRpc::Conformance::Classifier.new(references: [ small, large ]).classify(target)

    assert_equal "bcer-7.0", result[:classified_as]
  end

  def test_empty_references_classifies_as_nothing
    target = fingerprint(rpc_names: %w[A B])

    result = RpmsRpc::Conformance::Classifier.new(references: []).classify(target)

    assert_nil result[:classified_as]
    assert_equal 0.0, result[:coverage]
    assert_equal [], result[:ranked]
  end

  def test_ranked_entries_carry_package_coverage
    ref = fingerprint(
      release: "bcer-8.0",
      rpc_names: %w[A B],
      packages: { "PHARMACY" => "7.0", "MAILMAN" => "8.0" }
    )
    target = fingerprint(rpc_names: %w[A B], packages: { "MAILMAN" => "8.0", "PHARMACY" => "6.0" })

    result = RpmsRpc::Conformance::Classifier.new(references: [ ref ]).classify(target)

    assert_in_delta 0.5, result[:ranked].first[:package_coverage]
    assert_in_delta 0.5, result[:package_coverage]
  end

  def test_package_coverage_is_nil_when_reference_declares_no_packages
    # nil, not 1.0: "no package data on this reference" is a different fact
    # from "target meets every declared requirement" — and no divide-by-zero.
    ref = fingerprint(release: "bcer-5.0", rpc_names: %w[A])
    target = fingerprint(rpc_names: %w[A], packages: { "MAILMAN" => "8.0" })

    result = RpmsRpc::Conformance::Classifier.new(references: [ ref ]).classify(target)

    assert_nil result[:ranked].first[:package_coverage]
    assert_nil result[:package_coverage]
  end

  def test_package_coverage_counts_only_versions_the_target_meets
    ref = fingerprint(
      release: "bcer-8.0",
      packages: { "A PKG" => "2.0", "B PKG" => "1.0", "C PKG" => "3.0", "D PKG" => "" }
    )
    target = fingerprint(
      packages: { "A PKG" => "2.0", "B PKG" => "0.9", "D PKG" => "" } # C absent, B too low
    )

    result = RpmsRpc::Conformance::Classifier.new(references: [ ref ]).classify(target)

    assert_in_delta 0.5, result[:ranked].first[:package_coverage]
  end

  def test_package_signal_does_not_change_rpc_based_classification
    # The rpc-coverage winner stays classified_as even when the loser has
    # perfect package coverage — package_coverage is additive, not ranked on.
    rpc_winner = fingerprint(release: "bcer-8.0", rpc_names: %w[A B],
                             packages: { "PHARMACY" => "9.9" })
    pkg_winner = fingerprint(release: "bcer-5.0", rpc_names: %w[A X],
                             packages: { "PHARMACY" => "1.0" })
    target = fingerprint(rpc_names: %w[A B], packages: { "PHARMACY" => "1.0" })

    result = RpmsRpc::Conformance::Classifier.new(references: [ rpc_winner, pkg_winner ]).classify(target)

    assert_equal "bcer-8.0", result[:classified_as]
    assert_in_delta 0.0, result[:ranked].first[:package_coverage]
    assert_in_delta 1.0, result[:ranked].last[:package_coverage]
  end

  def test_no_references_yields_nil_package_coverage
    result = RpmsRpc::Conformance::Classifier.new(references: []).classify(fingerprint)

    assert_nil result[:package_coverage]
  end

  def test_empty_rpc_sets_do_not_divide_by_zero
    empty_ref = fingerprint(release: "bcer-5.0", rpc_names: [])
    empty_target = fingerprint(rpc_names: [])

    result = RpmsRpc::Conformance::Classifier.new(references: [ empty_ref ]).classify(empty_target)

    assert_equal "bcer-5.0", result[:classified_as]
    assert_equal 0.0, result[:coverage]
  end

  # Integration: the bcer-8.0 seed reference carries a SEED packages face;
  # staging has no packages captured, so bcer-8.0's package_coverage is 0.0
  # while bcer-5.0 (no packages declared) stays nil — and the RPC-based
  # classification is untouched by either.
  def test_staging_probe_reports_package_coverage_against_committed_references
    staging = RpmsRpc::Conformance::FixtureReader.new(
      File.join(FIXTURES_DIR, "staging-2026-06-07.yml")
    ).fingerprint
    references = Dir.glob(File.join(FIXTURES_DIR, "references", "*.yml")).sort.map do |path|
      RpmsRpc::Conformance::FixtureReader.new(path).fingerprint
    end

    result = RpmsRpc::Conformance::Classifier.new(references: references).classify(staging)

    by_release = result[:ranked].to_h { |entry| [ entry[:release], entry[:package_coverage] ] }
    assert_in_delta 0.0, by_release.fetch("bcer-8.0")
    assert_nil by_release.fetch("bcer-5.0")
    assert_equal "bcer-5.0", result[:classified_as]
  end
end
