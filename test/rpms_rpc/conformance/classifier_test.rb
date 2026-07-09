# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/conformance/classifier"

class RpmsRpc::Conformance::ClassifierTest < Minitest::Test
  def fingerprint(release: nil, rpc_names: [])
    RpmsRpc::Conformance::Fingerprint.from_h(
      "release" => release,
      "rpcs" => rpc_names.to_h { |name| [name, {}] }
    )
  end

  def test_classifies_as_the_highest_coverage_reference
    old_rung = fingerprint(release: "bcer-5.0", rpc_names: %w[A B C D])
    new_rung = fingerprint(release: "bcer-8.0", rpc_names: %w[A B C D E F G H])
    target = fingerprint(rpc_names: %w[A B C D E])

    result = RpmsRpc::Conformance::Classifier.new(references: [new_rung, old_rung]).classify(target)

    assert_equal "bcer-5.0", result[:classified_as]
    assert_in_delta 1.0, result[:coverage]
    assert_equal %w[bcer-5.0 bcer-8.0], result[:ranked].map { |r| r[:release] }
    assert_in_delta 5.0 / 8, result[:ranked].last[:coverage]
  end

  def test_coverage_counts_only_reference_rpcs_present_on_target
    ref = fingerprint(release: "bcer-8.0", rpc_names: %w[A B C D])
    target = fingerprint(rpc_names: %w[A B X Y Z])

    result = RpmsRpc::Conformance::Classifier.new(references: [ref]).classify(target)

    assert_in_delta 0.5, result[:coverage]
  end

  def test_ties_break_by_smallest_symmetric_difference
    # Both rungs fully covered (coverage 1.0); the bigger rung shares more
    # of the target's surface (smaller symmetric difference), so it wins.
    small = fingerprint(release: "bcer-5.0", rpc_names: %w[A B])
    large = fingerprint(release: "bcer-7.0", rpc_names: %w[A B C D])
    target = fingerprint(rpc_names: %w[A B C D E])

    result = RpmsRpc::Conformance::Classifier.new(references: [small, large]).classify(target)

    assert_equal "bcer-7.0", result[:classified_as]
  end

  def test_empty_references_classifies_as_nothing
    target = fingerprint(rpc_names: %w[A B])

    result = RpmsRpc::Conformance::Classifier.new(references: []).classify(target)

    assert_nil result[:classified_as]
    assert_equal 0.0, result[:coverage]
    assert_equal [], result[:ranked]
  end

  def test_empty_rpc_sets_do_not_divide_by_zero
    empty_ref = fingerprint(release: "bcer-5.0", rpc_names: [])
    empty_target = fingerprint(rpc_names: [])

    result = RpmsRpc::Conformance::Classifier.new(references: [empty_ref]).classify(empty_target)

    assert_equal "bcer-5.0", result[:classified_as]
    assert_equal 0.0, result[:coverage]
  end
end
