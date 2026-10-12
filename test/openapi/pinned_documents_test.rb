# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "yaml"
require "rpms_rpc"
require "rpms_rpc/conformance/inventory_lock"
require_relative "../../tools/openapi/surface"
require_relative "../../tools/openapi/client_api"
require_relative "../../tools/api_coverage/api_coverage"

# The two documents as they would be released (rpms-rpc#395 AC 1), generated from the real pinned build
# and the real lib/ tree: valid OpenAPI 3.1, every verb + path unique, every RPC addressed once, and the
# same inputs give the same bytes.
class OpenApiPinnedDocumentsTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  GEM = { "name" => "rpms-rpc", "version" => RpmsRpc::VERSION, "commit" => "0" * 40 }.freeze

  def self.inventory
    @inventory ||= begin
      tag = YAML.safe_load_file(File.join(ROOT, "data/rpc_coverage/config.yml")).fetch("release")
      RpmsRpc::Conformance::InventoryLock.verify_dir(tag, File.join(ROOT, "data/inventories", tag))
    end
  end

  def self.surface_text
    @surface_text ||= OpenApi.pretty(OpenApi::Surface.document(inventory.surface, build: OpenApi.build_provenance(inventory), gem: GEM))
  end

  def self.methods
    @methods ||= begin
      r = ApiCoverage.build(ROOT)
      JSON.parse(JSON.generate(ApiCoverage.document(r[:entries], registry_tag: r[:registry_tag])))
    end
  end

  def self.api_text = (@api_text ||= OpenApi.pretty(OpenApi::ClientApi.document(methods, gem: GEM)))

  def test_the_surface_is_valid_and_addresses_every_registered_rpc_once
    doc = JSON.parse(self.class.surface_text)
    assert_empty OpenApi.problems(doc)
    assert_empty OpenApi.schema_problems(doc)
    rpcs = OpenApi.operations(doc["paths"]).map { |_, _, o| o["x-rpms"]["rpc"] }
    assert_equal self.class.inventory.surface.names.sort, rpcs.sort
    # Duplicate keys would collapse silently on parse, so count the operation lines in the raw text too.
    assert_equal rpcs.size, self.class.surface_text.scan(/^ {6}"(get|post|put|delete)": \{$/).size
    assert_equal self.class.inventory.tag, doc["x-rpms-build"]["tag"]
    assert_equal self.class.inventory.build_commit, doc["x-rpms-build"]["rpms_ops_commit"]
    assert_equal self.class.inventory.surface.reach_counts, doc["x-rpms-counts"]["reach"]
  end

  def test_the_surface_counts_every_8994_parameter_the_walk_reports
    walk = File.binread(self.class.inventory.asset("rpc_signatures.txt"))[/parameters=(\d+)/, 1].to_i
    assert_equal walk, JSON.parse(self.class.surface_text)["x-rpms-counts"]["parameters"]["8994"]
  end

  def test_the_client_api_is_valid_and_places_every_rpc_backed_method
    doc = JSON.parse(self.class.api_text)
    assert_empty OpenApi.problems(doc)
    assert_empty OpenApi.schema_problems(doc)
    api = doc["x-rpms-api"]
    ids = OpenApi.operations(doc["paths"]).map { |_, _, o| o["operationId"] }
    placed = ids + api["folded"] + api["excluded"].values.flatten
    assert_equal self.class.methods["methods"].map { |m| "#{m['module'].delete_prefix('RpmsRpc::')}.#{m['method']}" }.sort, placed.sort
    assert_equal api["operations"], ids.size
    assert_equal self.class.methods["registry"], doc["x-rpms-build"]["tag"]
  end

  def test_the_same_inputs_give_byte_identical_documents
    inv = self.class.inventory
    again = OpenApi.pretty(OpenApi::Surface.document(RpmsRpc::Conformance::BuildSurface.load(inv.dir, inv.tag),
                                                     build: OpenApi.build_provenance(inv), gem: GEM))
    assert_equal self.class.surface_text, again
    assert_equal self.class.api_text, OpenApi.pretty(OpenApi::ClientApi.document(JSON.parse(JSON.generate(self.class.methods)), gem: GEM))
  end

  def test_a_broken_document_fails_its_checks
    doc = JSON.parse(self.class.api_text)
    path, item = doc["paths"].first
    doc["paths"]["#{path}/x"] = item
    doc["paths"]["/bad"] = { "get" => { "operationId" => 7 } }
    assert(OpenApi.problems(doc).any? { |p| p.include?("operationId") })
    refute_empty OpenApi.schema_problems(doc)
    doc2 = JSON.parse(self.class.api_text)
    doc2["paths"]["/patients/{x}"] = doc2["paths"]["/patients/{dfn}"]
    assert(OpenApi.problems(doc2).any? { |p| p.include?("GET /patients/{} is 2 operations") })
  end
end
