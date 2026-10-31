# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "rpms_rpc"
require_relative "../../tools/api_coverage/api_coverage"
require_relative "../../tools/openapi/client_api"

# Issue #389: declared resource/verb/path per public API method; rpc:api_coverage reports shape.
class ShapeTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  BASELINE = File.join(__dir__, "undeclared_baseline.txt")
  WRITE_CLASS_GET_BASELINE = File.join(ROOT, "data/openapi/write_class_get_baseline.txt")
  # Baseline line count when the ratchet was introduced; may only be lowered.
  UNDECLARED_BASELINE_MAX_LINES = 116
  # Frozen exception (#471): write-class methods that stay GET until reclassified read; may only shrink.
  WRITE_CLASS_GET_BASELINE_LINE_COUNT = 68

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

  def test_every_read_method_published_as_get_is_declared
    report = ApiCoverage.build(ROOT)
    violations = undeclared_read_methods_published_as_get(report)

    assert_empty violations,
                 "undeclared read methods published as GET in OpenAPI catalog:\n" \
                 "#{violations.join("\n")}"
  end

  def test_write_class_methods_published_as_get_honors_injected_retry_table_for_catalog_verbs
    report = ApiCoverage.build(ROOT)
    key = "RpmsRpc::Patient.find"
    retry_table = RpmsRpc::RetrySafety.table.merge(key => :non_idempotent_write)

    doc = JSON.parse(JSON.generate(ApiCoverage.document(report[:entries], registry_tag: report[:registry_tag])))
    catalog_entry = OpenApi::ClientApi.catalog(doc, retry_table: retry_table)[:entries].find do |e|
      m = e[:method]
      "#{m["module"]}.#{m["method"]}" == key
    end
    refute_nil catalog_entry, "expected #{key} in catalog"
    assert_equal "POST", catalog_entry[:addr][:verb].upcase

    violations = write_class_methods_published_as_get(report, retry_table: retry_table, allowed: [])
    patient_violations = violations.grep(/\A#{Regexp.escape(key)}:/)
    assert_empty patient_violations,
                 "injected retry table publishes #{key} as POST; helper must not report GET:\n" \
                 "#{patient_violations.join("\n")}"
  end

  def test_retry_safety_table_governs_publish_post_for_synthetic_methods
    m = {
      module: "RpmsRpc::ShapeTest::RetryPublishPost",
      method: "payload_snapshot",
      shape_status: "undeclared",
      rpcs: [ { name: "SYNTH", registered: true, entry_point: "X^SYNTH", reach: "client-callable", via: "literal" } ]
    }
    catalog_method = {
      "module" => m[:module], "method" => m[:method], "arity" => 1,
      "params" => [ { "name" => "ien", "kind" => "req" } ],
      "rpcs" => m[:rpcs].map { |r| r.transform_keys(&:to_s) },
      "unresolved" => [], "live_specs" => [], "personas" => [], "status" => "not_in_contract"
    }
    key = "#{m[:module]}.#{m[:method]}"
    write_rows = { key => :non_idempotent_write }
    read_rows = { key => :read }

    write_table = RpmsRpc::RetrySafety.table.merge(write_rows)
    addr = OpenApi::ClientApi.address(catalog_method, retry_table: write_table)
    assert_equal "post", addr[:verb]
    assert_equal "retry-class", addr[:rule]
    assert_equal "/retry-publish-posts/{ien}/payload-snapshot", addr[:path]

    read_table = RpmsRpc::RetrySafety.table.merge(read_rows)
    addr = OpenApi::ClientApi.address(catalog_method, retry_table: read_table)
    assert_equal "get", addr[:verb]
    assert_equal "noun", addr[:rule]
  end

  def test_every_write_class_method_is_published_with_a_non_get_verb
    report = ApiCoverage.build(ROOT)
    baseline = load_write_class_get_baseline
    violations = write_class_methods_published_as_get(report, allowed: baseline)
    stale = stale_write_class_get_baseline_entries(report, baseline: baseline)

    assert_empty violations,
                 "retry class other than :read must not be published as GET unless in write_class_get baseline:\n" \
                 "#{violations.join("\n")}"
    assert_empty stale,
                 "stale write_class_get baseline entries (no longer write-class GET in catalog):\n" \
                 "#{stale.join("\n")}"
  end

  def test_write_class_get_baseline_lists_only_write_class_methods_published_as_get
    baseline = load_write_class_get_baseline
    report = ApiCoverage.build(ROOT)
    published_keys = write_class_methods_published_as_get(report, allowed: []).map do |line|
      line.split(": ", 2).first
    end.to_set
    problems = baseline.filter_map do |line|
      if published_keys.include?(line)
        nil
      else
        "#{line}: not a write-class method published as GET in the catalog"
      end
    end

    assert_empty problems, problems.join("\n")
  end

  def test_write_class_get_baseline_has_no_duplicates_and_bounded_size
    lines = load_write_class_get_baseline
    duplicates = lines.tally.select { |_line, count| count > 1 }.keys

    assert_empty duplicates,
                 "duplicate write_class_get baseline entries:\n#{duplicates.join("\n")}"
    assert_equal WRITE_CLASS_GET_BASELINE_LINE_COUNT, lines.size,
                 "write_class_get baseline has #{lines.size} lines; update WRITE_CLASS_GET_BASELINE_LINE_COUNT when shrinking"
  end

  def test_every_get_declaration_is_classified_read
    mod = Module.new do
      def self.get_on_non_read; end
    end
    mod_name = "RpmsRpc::ShapeTest::GetOnNonRead"
    mod.define_singleton_method(:name) { mod_name }
    shape = { resource: "shape_test", verb: "GET", path: "/shape_test/get_on_non_read" }
    RpmsRpc::Shape.declare(mod, :get_on_non_read, **shape)

    synthetic_entry = {
      module: mod_name,
      method: "get_on_non_read",
      shape_status: "declared",
      shape: shape
    }
    retry_table = RpmsRpc::RetrySafety.table.merge("#{mod_name}.get_on_non_read" => :non_idempotent_write)
    synthetic_violations = declared_get_declarations_not_classified_read(
      [ synthetic_entry ],
      retry_table: retry_table
    )
    refute_empty synthetic_violations,
                 "helper must flag GET declared on a non-read retry class"
    assert_match(/requires retry class read/, synthetic_violations.join("\n"))

    report = ApiCoverage.build(ROOT)
    violations = declared_get_declarations_not_classified_read(report[:entries])
    assert_empty violations,
                 "GET-declared methods must be classified read in retry_safety.yml:\n" \
                 "#{violations.join("\n")}"
  ensure
    undeclare_shape(mod, :get_on_non_read) if mod
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
    %w[PATCH FETCH].each do |verb|
      mod = Module.new { def self.placeholder; end }
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

    validate_shape = RpmsRpc::Shape.for(RpmsRpc::Vital, :validate)
    assert_equal "POST", validate_shape[:verb]
    assert_equal "/patients/{dfn}/vitals/validate", validate_shape[:path]

    rpc_sending = ApiCoverage.build(ROOT)[:entries].select do |e|
      e[:module] == "RpmsRpc::Vital" && !e[:rpcs].empty?
    end
    refute_empty rpc_sending, "expected Vital methods that send RPCs"

    rpc_sending.each do |e|
      assert_equal "declared", e[:shape_status], "#{e[:module]}.#{e[:method]}"
    end
  end

  def test_every_declaration_names_an_api_coverage_entry
    listed = ApiCoverage.build(ROOT)[:entries].to_h { |e| [ [ e[:module], e[:method] ], true ] }

    unlisted = RpmsRpc::Shape.all.filter_map do |(mod, meth), _shape|
      next if mod.name.nil? || mod.name.empty?

      label = "#{mod.name}.#{meth}"
      next label unless listed[[ mod.name, meth.to_s ]]
    end

    assert_empty unlisted,
                 "declarations must name an api_coverage entry:\n#{unlisted.sort.join("\n")}"
  end

  def test_declared_shapes_have_no_verb_and_path_conflicts
    entries = ApiCoverage.build(ROOT)[:entries]
    conflicts = ApiCoverage.shape_conflicts(entries)
    message = conflicts.map do |group|
      shape = group.first[:shape]
      methods = group.map { |e| "#{e[:module]}.#{e[:method]}" }.sort.join(", ")
      "#{shape[:verb]} #{shape[:path]}: #{methods}"
    end.join("\n")

    assert_empty conflicts, message
  end

  def test_declared_shapes_match_openapi_client_api
    report = ApiCoverage.build(ROOT)
    declared_entries = report[:entries].select { |e| e[:shape_status] == "declared" }
    vital_entries = declared_entries.select { |e| e[:module] == "RpmsRpc::Vital" }
    refute_empty vital_entries, "expected declared Vital shapes"

    # Vital was slice 1; later slices declare more modules. This loop guards every declared module.
    refute_empty declared_entries, "expected at least one declared shape"
    mismatches = declared_shape_catalog_mismatches(report[:entries], registry_tag: report[:registry_tag])
    assert_empty mismatches, mismatches.join("\n")
  end

  def test_declared_shapes_compared_against_catalog_not_first_choice_address
    report = ApiCoverage.build(ROOT)
    entries = JSON.parse(JSON.generate(report[:entries]), symbolize_names: true)
    lookup = entries.find { |e| e[:module] == "RpmsRpc::Patient" && e[:method] == "lookup" }
    refute_nil lookup, "expected Patient.lookup in api_coverage entries"

    declare_lookup = lambda do |path|
      copy = JSON.parse(JSON.generate(entries), symbolize_names: true)
      row = copy.find { |e| e[:module] == "RpmsRpc::Patient" && e[:method] == "lookup" }
      row[:shape_status] = "declared"
      row[:shape] = { resource: "patients", verb: "GET", path: path }
      copy
    end

    wrong = declared_shape_catalog_mismatches(declare_lookup.call("/patients"), registry_tag: report[:registry_tag])
    refute_empty wrong,
                 "GET /patients on lookup should disagree with catalog (search owns the collection)"
    assert wrong.any? { |line| line.include?("RpmsRpc::Patient.lookup") }, wrong.join("\n")

    right = declared_shape_catalog_mismatches(declare_lookup.call("/patients/lookup"), registry_tag: report[:registry_tag])
    assert_empty right, right.join("\n")
  end

  def test_methods_json_carries_shape_for_declared_and_marks_undeclared
    report = ApiCoverage.build(ROOT)
    doc = ApiCoverage.document(report[:entries], registry_tag: report[:registry_tag])

    for_patient = doc[:methods].find { |e| e[:module] == "RpmsRpc::Vital" && e[:method] == "for_patient" }
    assert for_patient, "missing Vital.for_patient entry"

    shape = for_patient[:shape]
    refute_nil shape
    assert_equal %i[path resource verb], shape.keys.sort
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

  def test_declare_rejects_method_not_publicly_callable_on_module
    mod = Module.new do
      extend self
      def a; end
      private_class_method :a
    end
    refute mod.respond_to?(:a), "private_class_method must hide :a from callers"
    assert_raises(ArgumentError) do
      RpmsRpc::Shape.declare(mod, :a, resource: "vitals", verb: "GET", path: "/vitals")
    end
  end

  def test_declare_accepts_only_methods_defined_by_the_module_itself
    extend_self_mod = Module.new do
      extend self
      def real; end

      private

      def helper; end
    end
    singleton_mod = Module.new do
      def self.real; end
    end
    valid_shape = { resource: "vitals", verb: "GET", path: "/vitals" }

    %i[name freeze print open send].each do |method|
      assert_raises(ArgumentError) do
        RpmsRpc::Shape.declare(extend_self_mod, method, **valid_shape)
      end
    end

    assert_raises(ArgumentError) do
      RpmsRpc::Shape.declare(extend_self_mod, :helper, **valid_shape)
    end

    assert_declare_rejected(RpmsRpc::Vital, :invalid_id?, valid_shape)
    assert_declare_rejected(RpmsRpc::Vital, :shape, valid_shape)

    RpmsRpc::Shape.declare(extend_self_mod, :real, **valid_shape)
    RpmsRpc::Shape.declare(singleton_mod, :real, **valid_shape)
  end

  def test_redeclaring_with_different_shape_raises
    mod = Module.new { def self.slot; end }
    first = { resource: "vitals", verb: "GET", path: "/vitals" }
    second = { resource: "vitals", verb: "GET", path: "/vitals/alt" }

    RpmsRpc::Shape.declare(mod, :slot, **first)
    assert_raises(ArgumentError) do
      RpmsRpc::Shape.declare(mod, :slot, **second)
    end
  end

  def test_redeclaring_with_identical_shape_is_idempotent
    mod = Module.new { def self.slot; end }
    shape = { resource: "vitals", verb: "GET", path: "/vitals" }

    RpmsRpc::Shape.declare(mod, :slot, **shape)
    RpmsRpc::Shape.declare(mod, :slot, **shape)
  end

  def test_declare_validates_resource_and_path
    mod = Module.new { def self.slot; end }
    verb = "GET"
    invalid = [
      { resource: nil, path: nil },
      { resource: nil, path: "/vitals" },
      { resource: "", path: "/vitals" },
      { resource: "vitals", path: "vitals" },
      { resource: "vitals", path: "/vitals/" }
    ]

    invalid.each do |attrs|
      assert_raises(ArgumentError) do
        RpmsRpc::Shape.declare(mod, :slot, verb: verb, **attrs)
      end
    end
  end

  def test_declare_rejects_resource_with_surrounding_whitespace
    mod = Module.new do
      extend self
      def real; end
    end
    shape = { resource: " vitals ", verb: "GET", path: "/vitals" }

    assert_raises(ArgumentError) do
      RpmsRpc::Shape.declare(mod, :real, **shape)
    end
  end

  def test_declare_rejects_non_canonical_paths
    mod = Module.new do
      extend self
      def real; end
    end
    valid_shape = { resource: "vitals", verb: "GET" }

    [
      "/a//b",
      "/a/./b",
      "/a/../b",
      "/a b",
      "/a?q=1",
      "/a#x",
      "/a\n"
    ].each do |path|
      assert_raises(ArgumentError) do
        RpmsRpc::Shape.declare(mod, :real, **valid_shape, path: path)
      end
    end

    RpmsRpc::Shape.declare(mod, :real, **valid_shape, path: "/patients/{dfn}/vitals")
    singleton = Module.new { def self.real; end }
    RpmsRpc::Shape.declare(singleton, :real, **valid_shape, path: "/")
  end

  def test_declare_rejects_malformed_path_placeholders
    mod = Module.new do
      extend self
      def real; end
    end
    valid_shape = { resource: "vitals", verb: "GET" }
    malformed = [
      "/p/{dfn",
      "/p/dfn}",
      "/p/{}",
      "/p/{a/b}",
      "/p/{a}{b}"
    ]

    malformed.each do |path|
      assert_raises(ArgumentError, "expected ArgumentError for path #{path.inspect}") do
        RpmsRpc::Shape.declare(mod, :real, **valid_shape, path: path)
      end
    end

    RpmsRpc::Shape.declare(mod, :real, **valid_shape, path: "/patients/{dfn}/vitals")

    adjacent = Module.new do
      extend self
      def slot; end
    end
    RpmsRpc::Shape.declare(adjacent, :slot, **valid_shape, path: "/p/{a}/{b}")
  end

  def test_declare_rejects_resource_that_is_not_a_single_token
    mod = Module.new do
      extend self
      def real; end
    end
    shape = { verb: "GET", path: "/vitals" }

    [ "r\nx", "vital signs" ].each do |resource|
      assert_raises(ArgumentError, "expected ArgumentError for resource #{resource.inspect}") do
        RpmsRpc::Shape.declare(mod, :real, **shape, resource: resource)
      end
    end

    RpmsRpc::Shape.declare(mod, :real, **shape, resource: "vitals")
  end

  def test_declared_shape_strings_are_frozen_copies
    mod = Module.new do
      extend self
      def real; end
    end
    path = +"/x"
    RpmsRpc::Shape.declare(mod, :real, resource: "vitals", verb: "GET", path: path)
    path << "/y"

    shape = RpmsRpc::Shape.for(mod, :real)
    assert_equal "/x", shape[:path]
    assert shape[:path].frozen?
    assert shape[:resource].frozen?
    assert shape[:verb].frozen?
  end

  def test_shape_conflicts_treats_placeholder_names_as_same_route
    entry = lambda do |verb, path, method|
      {
        module: "Synthetic",
        method: method,
        rpcs: [ { name: "SYNTH RPC" } ],
        shape_status: "declared",
        shape: { resource: "vitals", verb: verb, path: path }
      }
    end

    dfn_path = entry.call("GET", "/patients/{dfn}/vitals", "with_dfn")
    id_path = entry.call("GET", "/patients/{id}/vitals", "with_id")
    conflicts = ApiCoverage.shape_conflicts([ dfn_path, id_path ])
    refute_empty conflicts,
                 "expected conflict for paths that differ only in placeholder name"

    post = entry.call("POST", "/patients/{dfn}/vitals", "post_variant")
    assert_empty ApiCoverage.shape_conflicts([ dfn_path, post ])
  end

  def test_undeclared_baseline_has_no_duplicates_and_bounded_size
    lines = File.readlines(BASELINE, chomp: true).reject(&:empty?)
    duplicates = lines.tally.select { |_line, count| count > 1 }.keys

    assert_empty duplicates,
                 "duplicate baseline entries:\n#{duplicates.join("\n")}"
    assert_operator lines.size, :<=, UNDECLARED_BASELINE_MAX_LINES,
                    "baseline has #{lines.size} lines; lower UNDECLARED_BASELINE_MAX_LINES when shrinking"
  end

  # OpenApi::ClientApi.catalog keyed by [module, method], same source as declared_shape_catalog_mismatches.
  def openapi_catalog_by_method(entries, registry_tag:, retry_table: RpmsRpc::RetrySafety.table)
    doc = JSON.parse(JSON.generate(ApiCoverage.document(entries, registry_tag: registry_tag)))
    catalog = OpenApi::ClientApi.catalog(doc, retry_table: retry_table)
    catalog[:entries].to_h do |e|
      m = e[:method]
      [ [ m["module"], m["method"] ], e ]
    end
  end

  # Declared GET shapes must name methods classified :read in retry_safety.yml.
  def declared_get_declarations_not_classified_read(entries, retry_table: RpmsRpc::RetrySafety.table)
    entries.filter_map do |entry|
      next unless entry[:shape_status] == "declared"
      next unless entry[:shape] && entry[:shape][:verb].to_s.upcase == "GET"

      key = "#{entry[:module]}.#{entry[:method]}"
      next if retry_table[key] == :read

      "#{key}: a GET declaration requires retry class read; reclassify or declare another verb"
    end.sort
  end

  def load_write_class_get_baseline
    File.readlines(WRITE_CLASS_GET_BASELINE, chomp: true).reject(&:empty?)
  end

  # RPC-sending methods whose retry class is not :read and are published GET in the catalog.
  # Returns violation lines; entries in `allowed` are exempt (frozen baseline).
  def write_class_methods_published_as_get(report, retry_table: RpmsRpc::RetrySafety.table, allowed: nil)
    allowed_set = (allowed || load_write_class_get_baseline).to_set
    catalog_by_method = openapi_catalog_by_method(
      report[:entries],
      registry_tag: report[:registry_tag],
      retry_table: retry_table
    )

    report[:entries].filter_map do |entry|
      next if entry[:rpcs].empty?

      key = "#{entry[:module]}.#{entry[:method]}"
      retry_class = retry_table[key]
      next if retry_class == :read

      catalog_entry = catalog_by_method[[ entry[:module], entry[:method] ]]
      next unless catalog_entry
      next unless catalog_entry[:addr][:verb].upcase == "GET"
      next if allowed_set.include?(key)

      "#{key}: GET #{catalog_entry[:addr][:path]} (#{retry_class})"
    end.sort
  end

  # Baseline keys that are not write-class methods published as GET (stale; baseline may only shrink).
  def stale_write_class_get_baseline_entries(report, baseline: nil, retry_table: RpmsRpc::RetrySafety.table)
    baseline_lines = baseline || load_write_class_get_baseline
    published_keys = write_class_methods_published_as_get(report, retry_table: retry_table, allowed: []).map do |line|
      line.split(": ", 2).first
    end.to_set
    baseline_lines.reject { |key| published_keys.include?(key) }.sort
  end

  # RPC-sending methods classified read in retry_safety.yml and published GET in the catalog, still undeclared.
  def undeclared_read_methods_published_as_get(report)
    retry_table = RpmsRpc::RetrySafety.table
    catalog_by_method = openapi_catalog_by_method(report[:entries], registry_tag: report[:registry_tag])

    report[:entries].filter_map do |entry|
      next if entry[:rpcs].empty?
      next unless entry[:shape_status] != "declared"

      key = "#{entry[:module]}.#{entry[:method]}"
      next unless retry_table[key] == :read

      catalog_entry = catalog_by_method[[ entry[:module], entry[:method] ]]
      next unless catalog_entry
      next unless catalog_entry[:addr][:verb].upcase == "GET"

      key
    end.sort
  end

  # Declared shapes must match where OpenApi::ClientApi.catalog publishes each method (not address()'s
  # first-choice route). Returns human-readable mismatch lines; empty when every declared shape matches.
  def declared_shape_catalog_mismatches(entries, registry_tag:)
    by_method = openapi_catalog_by_method(entries, registry_tag: registry_tag)

    entries.select { |e| e[:shape_status] == "declared" }.filter_map do |entry|
      catalog_entry = by_method[[ entry[:module], entry[:method] ]]
      label = "#{entry[:module]}.#{entry[:method]}"
      unless catalog_entry
        next "#{label}: declared shape is not published in OpenAPI catalog " \
             "(excluded as no_rpc/unresolved/unregistered, or folded into another operation)"
      end

      declared = entry[:shape]
      addr = catalog_entry[:addr]
      collection = catalog_entry[:collection]
      problems = []
      unless addr[:verb].upcase == declared[:verb]
        problems << "#{label} verb: declared #{declared[:verb]}, catalog #{addr[:verb].upcase}"
      end
      unless addr[:path] == declared[:path]
        problems << "#{label} path: declared #{declared[:path]}, catalog #{addr[:verb].upcase} #{addr[:path]}"
      end
      unless collection == declared[:resource]
        problems << "#{label} resource: declared #{declared[:resource].inspect}, catalog #{collection.inspect}"
      end
      problems.empty? ? nil : problems.join("; ")
    end
  end

  def assert_declare_rejected(mod, method, shape)
    raised = false
    begin
      RpmsRpc::Shape.declare(mod, method, **shape)
    rescue ArgumentError
      raised = true
    ensure
      undeclare_shape(mod, method) unless raised
    end
    assert raised, "expected ArgumentError declaring #{mod}.#{method}"
  end

  def undeclare_shape(mod, method)
    RpmsRpc::Shape.send(:declarations).delete([ mod, method.to_sym ])
  end
end
