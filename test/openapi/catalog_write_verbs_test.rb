# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "rpms_rpc"
require_relative "../../tools/openapi/client_api"
require_relative "../../tools/api_coverage/api_coverage"

# rpms-rpc#471: catalog HTTP verbs for save, send, and retry-safety alignment (SPEC only).
class OpenApiCatalogWriteVerbsTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  Api = OpenApi::ClientApi

  def req(*names) = names.map { |n| { "name" => n, "kind" => "req" } }
  def rpc(name) = { "name" => name, "registered" => true, "entry_point" => "X^#{name.split.first}", "reach" => "client-callable", "via" => "literal" }

  def method(mod, name, params = [], rpc: "SYNTH RPC")
    { "module" => "RpmsRpc::#{mod}", "method" => name, "arity" => params.size, "params" => params, "rpcs" => [ rpc(rpc) ],
      "unresolved" => [], "live_specs" => [], "personas" => [], "status" => "not_in_contract" }
  end

  def at(m)
    a = Api.address(m)
    "#{a[:verb].upcase} #{a[:path]}"
  end

  def method_key(m) = "#{m['module']}.#{m['method']}"

  # Hermetic retry rows for synthetic modules (not in retry_safety.yml).
  def with_retry_rows(rows)
    table = RpmsRpc::RetrySafety.table.merge(rows)
    RpmsRpc::RetrySafety.stub(:table, table) { yield }
  end

  def catalog_rule(m)
    Api.catalog({ "schema" => 1, "methods" => [ m ] })[:entries].fetch(0)[:op]["x-rpms"]["rule"]
  end

  def catalog_by_method(entries, registry_tag:)
    doc = JSON.parse(JSON.generate(ApiCoverage.document(entries, registry_tag: registry_tag)))
    Api.catalog(doc)[:entries].to_h do |e|
      m = e[:method]
      [ [ m["module"], m["method"] ], e ]
    end
  end

  def test_save_is_create_post_to_the_collection
    assert_equal "POST /patients/{dfn}/allergies", at(method("Allergy", "save", req("dfn", "allergy_fields"), rpc: "GMRA SAVE ALLERGY"))
    assert_equal "POST /patients/{dfn}/orders", at(method("Order", "save", req("dfn", "order_fields"), rpc: "ORWDX SAVE"))
  end

  def test_send_is_action_post_to_send
    assert_equal "POST /users/{duz}/notifications/send", at(method("Notifications", "send", req("duz", "payload"), rpc: "ORQQCN SEND"))
    assert_equal "POST /synthetic-messagings/{ien}/send", at(method("SyntheticMessaging", "send", req("ien"), rpc: "SYNTH SEND"))
  end

  def test_a_write_class_name_with_no_verb_falls_back_to_post_not_get
    # Not in write_class_get_baseline: a synthetic noun-shaped write-class method must not default to GET.
    assert_equal "POST /synthetic-writes/{ien}/payload-snapshot",
                 at(method("SyntheticWrite", "payload_snapshot", req("ien"), rpc: "SYNTH WRITE SNAPSHOT"))
  end

  def test_two_plain_noun_writes_in_one_module_do_not_collide
    snapshot = method("SyntheticWrite", "payload_snapshot", req("ien"), rpc: "SYNTH WRITE SNAPSHOT")
    audit = method("SyntheticWrite", "audit_trail", req("ien"), rpc: "SYNTH WRITE AUDIT")
    routes = [ snapshot, audit ].map { |m| at(m) }

    assert_equal 2, routes.uniq.size
    assert_equal "POST /synthetic-writes/{ien}/payload-snapshot", routes[0]
    assert_equal "POST /synthetic-writes/{ien}/audit-trail", routes[1]
  end

  def test_retry_safety_non_idempotent_write_noun_publishes_post_at_inferred_path
    m = method("SyntheticWrite", "payload_snapshot", req("ien"), rpc: "SYNTH WRITE SNAPSHOT")
    with_retry_rows({ method_key(m) => :non_idempotent_write }) do
      assert_equal "POST /synthetic-writes/{ien}/payload-snapshot", at(m)
      assert_equal "retry-class", catalog_rule(m)
    end
  end

  def test_retry_safety_idempotent_write_read_verb_name_publishes_post
    m = method("SyntheticRetry", "find_counterpart", req("ien"), rpc: "SYNTH FIND COUNTERPART")
    with_retry_rows({ method_key(m) => :idempotent_write }) do
      assert_equal "POST /synthetic-retries/{ien}/counterpart", at(m)
      assert_equal "retry-class", catalog_rule(m)
    end
  end

  def test_retry_safety_read_class_keeps_get_for_same_synthetic_names
    snapshot = method("SyntheticWrite", "payload_snapshot", req("ien"), rpc: "SYNTH WRITE SNAPSHOT")
    find_m = method("SyntheticRetry", "find_counterpart", req("ien"), rpc: "SYNTH FIND COUNTERPART")
    rows = { method_key(snapshot) => :read, method_key(find_m) => :read }
    with_retry_rows(rows) do
      assert_equal "GET /synthetic-writes/{ien}/payload-snapshot", at(snapshot)
      assert_equal "noun", catalog_rule(snapshot)
      assert_equal "GET /synthetic-retries/{ien}/counterpart", at(find_m)
      assert_equal "read", catalog_rule(find_m)
    end
  end

  WRITE_CLASS_GET_BASELINE = File.join(__dir__, "../../data/openapi/write_class_get_baseline.txt").freeze
  READ_GET_ROUTES = File.join(__dir__, "../fixtures/openapi/read_get_catalog_routes.tsv").freeze

  def test_baseline_write_class_method_stays_get_in_the_catalog
    report = ApiCoverage.build(ROOT)
    catalog = catalog_by_method(report[:entries], registry_tag: report[:registry_tag])
    entry = catalog[[ "RpmsRpc::Referral", "find" ]]
    refute_nil entry, "expected Referral.find in OpenAPI catalog"
    assert_equal "GET", entry[:addr][:verb].upcase
    assert_equal "/referrals/{ien}", entry[:addr][:path]

    baseline = File.readlines(WRITE_CLASS_GET_BASELINE, chomp: true).reject(&:empty?)
    assert_includes baseline, "RpmsRpc::Referral.find"
  end

  def test_every_read_class_method_keeps_get_verb_and_path_in_the_catalog
    expected = File.readlines(READ_GET_ROUTES, chomp: true).reject(&:empty?).to_h do |line|
      key, route = line.split("\t", 2)
      [ key, route ]
    end
    report = ApiCoverage.build(ROOT)
    retry_table = RpmsRpc::RetrySafety.table
    catalog = catalog_by_method(report[:entries], registry_tag: report[:registry_tag])
    actual = {}

    report[:entries].each do |entry|
      next if entry[:rpcs].empty?

      key = "#{entry[:module]}.#{entry[:method]}"
      next unless retry_table[key] == :read

      catalog_entry = catalog[[ entry[:module], entry[:method] ]]
      next unless catalog_entry && catalog_entry[:addr][:verb].upcase == "GET"

      actual[key] = "GET #{catalog_entry[:addr][:path]}"
    end

    assert_equal expected.keys.sort, actual.keys.sort,
                 "the set of :read methods published GET in the catalog changed; update #{READ_GET_ROUTES} only when intentional"
    mismatches = expected.filter_map do |key, route|
      next if actual[key] == route

      "#{key}: expected #{route}, catalog #{actual[key]}"
    end

    assert_empty mismatches,
                 "every existing GET read must keep its verb and path in the catalog:\n#{mismatches.join("\n")}"
  end
end
