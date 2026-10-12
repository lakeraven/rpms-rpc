# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "tmpdir"
require "rpms_rpc"
require_relative "../../tools/openapi/surface"
require_relative "../../tools/openapi/rpcs_pin"
require_relative "../../tools/openapi/client_api"
require_relative "../../tools/api_coverage/api_coverage"

# The two documents as they would be released (rpms-rpc#395 AC 1), generated from the real pinned
# <tag>-rpcs.json (data/openapi/, AC 2) and the real lib/ tree: valid OpenAPI 3.1, every verb + path
# unique, every RPC addressed once, and the same inputs give the same bytes. The pin is proven first.
class OpenApiPinnedDocumentsTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  GEM = { "name" => "rpms-rpc", "version" => RpmsRpc::VERSION, "commit" => "0" * 40 }.freeze
  PIN = OpenApi::RpcsPin

  def self.pin = (@pin ||= PIN.verify(ROOT))

  def self.surface_text
    @surface_text ||= OpenApi.pretty(OpenApi::Surface.document(pin[:surface], build: PIN.build_provenance(pin), gem: GEM))
  end

  def self.methods
    @methods ||= begin
      r = ApiCoverage.build(ROOT)
      JSON.parse(JSON.generate(ApiCoverage.document(r[:entries], registry_tag: r[:registry_tag])))
    end
  end

  def self.api_text = (@api_text ||= OpenApi.pretty(OpenApi::ClientApi.document(methods, gem: GEM)))

  def test_the_pin_is_the_committed_bytes_and_a_changed_byte_is_refused
    lock = PIN.lock(ROOT)
    assert_equal "#{lock['tag']}-rpcs.json", lock["asset"]
    assert_equal PIN.sha256(File.join(ROOT, PIN::DIR, lock["asset"])), lock["sha256"]
    assert_match(%r{\Alakeraven/rpms-ops@[0-9a-f]{40}:releases/schema/rpcs\.v1\.schema\.json\z}, lock["schema_source"])
    Dir.mktmpdir do |tmp|
      FileUtils.mkdir_p(File.join(tmp, "data"))
      FileUtils.cp_r(File.join(ROOT, PIN::DIR), File.join(tmp, "data"))
      file = File.join(tmp, PIN::DIR, lock["asset"])
      File.write(file, File.read(file).sub('"engine": "yottadb"', '"engine": "iris"'))
      e = assert_raises(OpenApi::Refused) { PIN.verify(tmp) }
      assert_match(/is not the pinned/, e.message)
    end
  end

  # The schema is closed: a field it does not define, or a schema name other than rpcs.v1, is refused.
  def test_a_file_that_is_not_rpcs_v1_is_refused
    doc = self.class.pin[:doc]
    schema = File.join(ROOT, PIN::SCHEMA_FILE)
    assert_empty PIN.schema_problems(doc, schema)
    refute_empty PIN.schema_problems(doc.merge("extra" => 1), schema)
    refute_empty PIN.schema_problems(doc.merge("schema" => "rpcs.v2"), schema)
    Dir.mktmpdir do |tmp|
      path = File.join(tmp, "x-rpcs.json")
      File.write(path, JSON.generate(doc.merge("schema" => "rpcs.v2")))
      e = assert_raises(RpmsRpc::Conformance::BuildSurface::Error) { RpmsRpc::Conformance::BuildSurface.from_rpcs_json(path) }
      assert_match(/schema "rpcs.v2", not rpcs.v1/, e.message)
    end
  end

  def test_the_surface_is_valid_and_addresses_every_registered_rpc_once
    doc = JSON.parse(self.class.surface_text)
    assert_empty OpenApi.problems(doc)
    assert_empty OpenApi.schema_problems(doc)
    rpcs = OpenApi.operations(doc["paths"]).map { |_, _, o| o["x-rpms"]["rpc"] }
    assert_equal(self.class.pin[:doc]["rpcs"].map { |r| r["name"] }.sort, rpcs.sort)
    # Duplicate keys would collapse silently on parse, so count the operation lines in the raw text too.
    assert_equal rpcs.size, self.class.surface_text.scan(/^ {6}"(get|post|put|delete)": \{$/).size
    build = doc["x-rpms-build"]
    assert_equal [ self.class.pin[:tag], self.class.pin[:doc]["commit"] ], build.values_at("tag", "rpms_ops_commit")
    assert_equal({ "file" => "#{self.class.pin[:tag]}-rpcs.json", "sha256" => self.class.pin[:sha256], "schema" => "rpcs.v1" }, build["source"])
    assert_equal self.class.pin[:surface].reach_counts, doc["x-rpms-counts"]["reach"]
  end

  def test_the_surface_counts_every_8994_parameter_rpcs_json_lists
    listed = self.class.pin[:doc]["rpcs"].sum { |r| r["parameters"].count { |p| p["source"] == "8994" } }
    assert_equal listed, JSON.parse(self.class.surface_text)["x-rpms-counts"]["parameters"]["8994"]
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
    pin = PIN.verify(ROOT)
    assert_equal self.class.surface_text, OpenApi.pretty(OpenApi::Surface.document(pin[:surface], build: PIN.build_provenance(pin), gem: GEM))
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
