# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require_relative "../../tools/api_coverage/api_coverage"

# Issue #389: declared resource/verb/path per public API method; rpc:api_coverage reports shape.
class ShapeTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  BASELINE = File.join(__dir__, "undeclared_baseline.txt")

  def test_every_public_method_that_sends_rpcs_is_declared_or_baselined
    report = ApiCoverage.build(ROOT)
    baseline = File.readlines(BASELINE, chomp: true).reject(&:empty?)
    violations = report[:entries].select do |e|
      next false if e[:rpcs].empty?

      undeclared = e[:shape_status] != "declared"
      next false unless undeclared

      key = "#{e[:module]}.#{e[:method]}"
      !baseline.include?(key)
    end

    assert_empty violations,
                 "undeclared RPC-sending methods not in baseline:\n" \
                 "#{violations.map { |e| "#{e[:module]}.#{e[:method]}" }.join("\n")}"
  end

  def test_baseline_lists_no_declared_or_missing_method
    baseline = File.readlines(BASELINE, chomp: true).reject(&:empty?)
    by_key = ApiCoverage.build(ROOT)[:entries].to_h { |e| [ "#{e[:module]}.#{e[:method]}", e ] }
    problems = baseline.filter_map do |line|
      entry = by_key[line]
      if entry.nil?
        "#{line}: no matching API entry"
      elsif entry[:rpcs].empty?
        "#{line}: entry sends no RPCs"
      elsif entry[:shape_status] == "declared"
        "#{line}: shape is declared; remove from baseline"
      elsif entry[:shape_status] != "undeclared"
        "#{line}: expected shape_status undeclared, got #{entry[:shape_status].inspect}"
      end
    end

    assert_empty problems, problems.join("\n")
  end

  def test_declare_rejects_unknown_verb
    mod = Module.new { def self.placeholder; end }
    RpmsRpc::Shape.declare(mod, :placeholder, resource: "vitals", verb: "GET", path: "/vitals")

    %w[PATCH FETCH].each do |verb|
      assert_raises(ArgumentError) do
        RpmsRpc::Shape.declare(mod, :placeholder, resource: "vitals", verb: verb, path: "/vitals")
      end
    end
  end

  def test_vital_methods_carry_declared_shape
    shape = RpmsRpc::Shape.for(RpmsRpc::Vital, :for_patient)

    assert_equal "GET", shape[:verb]
    refute_empty shape[:resource].to_s
    refute_empty shape[:path].to_s

    rpc_sending = ApiCoverage.build(ROOT)[:entries].select do |e|
      e[:module] == "RpmsRpc::Vital" && !e[:rpcs].empty?
    end
    refute_empty rpc_sending, "expected Vital methods that send RPCs"

    rpc_sending.each do |e|
      assert_equal "declared", e[:shape_status], "#{e[:module]}.#{e[:method]}"
    end
  end

  def test_methods_json_carries_shape_for_declared_and_marks_undeclared
    report = ApiCoverage.build(ROOT)
    doc = ApiCoverage.document(report[:entries], registry_tag: report[:registry_tag])

    for_patient = doc[:methods].find { |e| e[:module] == "RpmsRpc::Vital" && e[:method] == "for_patient" }
    assert for_patient, "missing Vital.for_patient entry"

    shape = for_patient[:shape]
    refute_nil shape
    assert_equal %i[resource verb path], shape.keys.sort
    refute_empty shape[:resource].to_s
    refute_empty shape[:verb].to_s
    refute_empty shape[:path].to_s
    assert_equal "declared", for_patient[:shape_status]

    undeclared = doc[:methods].find { |e| !e[:rpcs].empty? && e[:shape_status] == "undeclared" }
    assert undeclared, "need at least one undeclared RPC-sending method outside Vital"
    assert_nil undeclared[:shape]

    assert doc[:summary].key?(:undeclared), "summary missing undeclared count"
    assert_operator doc[:summary][:undeclared], :>=, 1
  end

  def test_duplicate_verb_and_path_is_a_conflict
    entry = lambda do |verb, path, resource: "synthetic"|
      {
        module: "Synthetic",
        method: "#{verb}_#{path.tr('/', '_')}",
        rpcs: [ { name: "SYNTH RPC" } ],
        shape_status: "declared",
        shape: { resource: resource, verb: verb, path: path }
      }
    end

    a = entry.call("GET", "/same")
    b = entry.call("GET", "/same", resource: "other")
    conflicts = ApiCoverage.shape_conflicts([ a, b ])
    refute_empty conflicts, "expected a conflict for duplicate verb+path"

    distinct = entry.call("GET", "/distinct")
    assert_empty ApiCoverage.shape_conflicts([ a, distinct ])
  end

  def test_a_declaration_for_a_nonexistent_method_fails
    mod = Module.new
    error = assert_raises { RpmsRpc::Shape.declare(mod, :not_defined_here, resource: "x", verb: "GET", path: "/x") }
    refute_match(/uninitialized constant/, error.message, "RpmsRpc::Shape must exist")
    assert_includes [ ArgumentError, NameError ], error.class
  end
end
