# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "rpms_rpc"
require_relative "../../tools/api_coverage/api_coverage"

# rake rpc:api_coverage (rpms-rpc#358): method discovery, RPC resolution and the JSON shape.
# The fixture is the real lib/ tree; nothing reaches a broker.
class ApiCoverageTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  API_DIR = File.join(ROOT, "lib/rpms_rpc/api")

  def methods
    @methods ||= ApiCoverage.public_methods_of(RpmsRpc, API_DIR).map { |mod, m| "#{mod.name}.#{m}" }
  end

  def resolver
    @resolver ||= ApiCoverage::Resolver.new(lib_dir: File.join(ROOT, "lib"), mappings: ApiCoverage.mapping_rpcs)
  end

  def def_node(source)
    ApiCoverage.defs_by_line(Prism.parse(source).value).values.grep(Prism::DefNode).first
  end

  # --- method discovery ----------------------------------------------------------------------

  def test_finds_public_module_methods_including_nested_modules
    assert_includes methods, "RpmsRpc::Patient.find"
    assert_includes methods, "RpmsRpc::Patient.search"
    assert_includes methods, "RpmsRpc::BehavioralHealth::CaseManagement.case_dates"
  end

  def test_leaves_out_private_methods_and_methods_defined_outside_api
    refute_includes methods, "RpmsRpc::Patient.external"
    refute_includes methods, "RpmsRpc::Patient.name"
    assert(methods.none? { |m| m.start_with?("RpmsRpc::DataMapper.") }, "DataMapper is not an API module")
  end

  def test_every_method_is_defined_under_lib_rpms_rpc_api
    ApiCoverage.public_methods_of(RpmsRpc, API_DIR).each do |mod, m|
      assert mod.method(m).source_location[0].start_with?("#{API_DIR}/"), "#{mod}.#{m}"
    end
  end

  # --- scanning a method body (source text) --------------------------------------------------

  def test_scan_reads_mappings_literals_and_constants
    s = ApiCoverage.scan_def(def_node(<<~'RUBY'), %i[patient_select patient_list])
      def f(dfn)
        DataMapper.patient_select.fetch_one(dfn)
        DataMapper[:patient_list].fetch_many("A")
        RpmsRpc.client.call_rpc("ORWU USERINFO")
        client.call_rpc_raw(CANRUN_RPC, "X")
      end
    RUBY

    assert_equal %i[patient_select patient_list], s.mappings
    assert_equal [ "ORWU USERINFO" ], s.literals
    assert_equal [ "CANRUN_RPC" ], s.constants
    assert_empty s.unresolved
  end

  def test_scan_reads_a_mapping_named_by_a_symbol_argument_but_not_a_hash_key
    s = ApiCoverage.scan_def(def_node(<<~'RUBY'), %i[amhg_case_dates ien])
      def f(dfn)
        rows(:amhg_case_dates, dfn).map { |r| { ien: r[:ien] } }
      end
    RUBY

    assert_equal %i[amhg_case_dates], s.mappings
  end

  def test_scan_records_names_that_come_from_locals_and_leaves_other_shapes_unresolved
    s = ApiCoverage.scan_def(def_node(<<~'RUBY'), [])
      def f(mapping, rpc_name)
        client.call_rpc(mapping.rpc_name)
        client.call_rpc(rpc_name)
        client.call_rpc(names.fetch(:x))
      end
    RUBY

    assert_equal %i[mapping rpc_name], s.from_locals.map { |l| l[:local] }
    assert_equal [ "names.fetch(:x)" ], s.unresolved
  end

  def test_bind_args_binds_positional_and_keyword_arguments
    callee = def_node("def call_array(client, rpc_name, *params, window: 1); end")
    call = Prism.parse('call_array(c, ADD_RPC, "a", window: 2)').value.statements.body.first
    bound = ApiCoverage.bind_args(callee, call.arguments.arguments).transform_values(&:slice)

    assert_equal({ client: "c", rpc_name: "ADD_RPC", window: "2" }, bound)
  end

  # --- resolution through the real lib/ tree -------------------------------------------------

  def test_resolves_mappings_to_their_rpcs
    assert_equal [ "ORWPT ID INFO", "ORWPT SELECT" ], resolver.resolve(RpmsRpc::Patient, :find)[:rpcs].map { |r| r[:name] }
  end

  def test_binds_a_constant_passed_to_a_helper_that_sends_it
    r = resolver.resolve(RpmsRpc::Agg, :add_patient)

    assert_includes r[:rpcs].map { |x| x[:name] }, "AGG ADD NEW PATIENT"
    assert_empty r[:unresolved]
  end

  def test_binds_a_mapping_symbol_through_a_mixed_in_helper
    r = resolver.resolve(RpmsRpc::BehavioralHealth::CaseManagement, :case_dates)

    assert_equal [ "AMHG GET CASE DATES" ], r[:rpcs].map { |x| x[:name] }
    assert_empty r[:unresolved]
  end

  def test_a_helper_whose_rpc_is_its_argument_is_unresolved_not_guessed
    r = resolver.resolve(RpmsRpc::Patient, :fetch_lookup_rows)

    assert_empty r[:rpcs]
    refute_empty r[:unresolved]
  end

  def test_an_attribute_accessor_sends_nothing
    assert_equal({ rpcs: [], unresolved: [] }, resolver.resolve(RpmsRpc::Registration, :hrn_mode))
  end

  # --- inputs --------------------------------------------------------------------------------

  def test_live_call_sites_finds_module_method_calls
    Dir.mktmpdir do |dir|
      path = File.join(dir, "x_live_test.rb")
      File.write(path, "class X\n  def test_a\n    RpmsRpc::Patient.find(3)\n    RpmsRpc::DataMapper.patient_select\n  end\nend\n")
      sites = ApiCoverage.live_call_sites([ path ], root: dir)

      assert_equal [ "x_live_test.rb:3" ], sites["RpmsRpc::Patient"][:find]
    end
  end

  def test_load_registry_reads_name_and_entry_point
    Dir.mktmpdir do |dir|
      path = File.join(dir, "r.txt")
      File.write(path, "# source: fixture\nORWPT SELECT^SELECT^ORWPT^2\nNO ENTRY^^\n")

      assert_equal({ "ORWPT SELECT" => "SELECT^ORWPT", "NO ENTRY" => nil }, ApiCoverage.load_registry(path))
    end
  end

  # --- the JSON ------------------------------------------------------------------------------

  def test_json_has_one_entry_per_public_method_in_the_documented_shape
    report = ApiCoverage.build(ROOT)
    doc = JSON.parse(JSON.generate(ApiCoverage.document(report[:entries], registry_tag: report[:registry_tag])))

    assert_equal %w[schema registry personas summary methods], doc.keys
    assert_equal methods.size, doc["methods"].size
    assert_equal %w[proven public unresolved_methods unregistered_rpcs by_module], doc["summary"].keys
    doc["methods"].each do |e|
      assert_equal %w[module method arity params rpcs unresolved live_specs personas status], e.keys
      assert_includes ApiCoverage::STATUSES, e["status"]
      assert_equal e["live_specs"].empty?, e["status"] == "not_in_contract"
      e["rpcs"].each { |r| assert_equal %w[name registered entry_point via], r.keys }
      e["live_specs"].each { |s| assert_match(%r{\Atest/live/.+\.rb:\d+\z}, s) }
    end
    find = doc["methods"].find { |e| e["module"] == "RpmsRpc::Patient" && e["method"] == "find" }
    assert_equal [ { "name" => "dfn", "kind" => "req" } ], find["params"]
  end
end
