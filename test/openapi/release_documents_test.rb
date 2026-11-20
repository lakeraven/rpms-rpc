# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "tmpdir"
require "rpms_rpc"
require_relative "../../tools/openapi/surface"
require_relative "../../tools/openapi/release_surface"
require_relative "../../tools/openapi/client_api"
require_relative "../../tools/api_coverage/api_coverage"
require_relative "../rpms_rpc/release_under_test"

# The two documents as they would be released (rpms-rpc#395 AC 1), generated from the <tag>-rpcs.json of the
# release under test (AC 2; `rake openrpms:fetch`, rpms-rpc#724) and the real lib/ tree: valid OpenAPI 3.1,
# every verb + path unique, every RPC addressed once, and the same inputs give the same bytes. With
# OPENRPMS_OFFLINE=1 those tests skip, saying so; the reader's refusals run offline on the committed fixture.
class OpenApiReleaseDocumentsTest < Minitest::Test
  GEM = { "name" => "rpms-rpc", "version" => RpmsRpc::VERSION, "commit" => "0" * 40 }.freeze
  SURFACE = OpenApi::ReleaseSurface
  ROOT = ReleaseUnderTest::ROOT

  def release = (@release ||= SURFACE.read(ReleaseUnderTest.inventory(self)))

  def surface_text
    @surface_text ||= OpenApi.pretty(OpenApi::Surface.document(release[:surface], build: SURFACE.build_provenance(release), gem: GEM))
  end

  def methods
    @methods ||= begin
      r = ApiCoverage.build(ROOT, surface: release[:surface])
      JSON.parse(JSON.generate(ApiCoverage.document(r[:entries], registry_tag: r[:registry_tag])))
    end
  end

  def api_text = (@api_text ||= OpenApi.pretty(OpenApi::ClientApi.document(methods, gem: GEM)))

  # The surface reads the bytes the fetch verified, through current.json; a changed byte is refused, and so is
  # a cache with nothing fetched.
  def test_the_surface_reads_the_recorded_release_and_refuses_a_changed_byte
    Dir.mktmpdir do |tmp|
      e = assert_raises(OpenApi::Refused) { SURFACE.read(root: tmp) }
      assert_match(/no openrpms release fetched/, e.message)

      tag = ReleaseUnderTest::FIXTURE_TAG
      FileUtils.cp_r(ReleaseUnderTest::FIXTURE_DIR, File.join(tmp, tag))
      RpmsRpc::Conformance::ReleaseInventory.record_current!(ReleaseUnderTest.fixture, root: tmp, chosen_by: "test")
      read = SURFACE.read(root: tmp)
      assert_equal tag, read[:tag]
      assert_equal RpmsRpc::Conformance::ReleaseInventory.sha256(read[:path]), read[:sha256]
      assert_equal({ "file" => "#{tag}-rpcs.json", "sha256" => read[:sha256], "schema" => read[:doc]["schema"] }, SURFACE.build_provenance(read)["source"])

      file = File.join(tmp, tag, "#{tag}-rpcs.json")
      File.write(file, File.read(file).sub('"engine": "yottadb"', '"engine": "iris"'))
      e = assert_raises(OpenApi::Refused) { SURFACE.read(root: tmp) }
      assert_match(/engine "iris" is not the provenance's "yottadb"/, e.message)
    end
  end

  def test_a_schema_the_reader_does_not_know_is_refused
    doc = JSON.parse(File.read(ReleaseUnderTest.fixture.rpcs_json))
    Dir.mktmpdir do |tmp|
      path = File.join(tmp, "x-rpcs.json")
      File.write(path, JSON.generate(doc.merge("schema" => "rpcs.v3")))
      e = assert_raises(RpmsRpc::Conformance::BuildSurface::Error) { RpmsRpc::Conformance::BuildSurface.from_rpcs_json(path) }
      assert_match(/schema "rpcs.v3", not one of rpcs.v1, rpcs.v2/, e.message)
    end
  end

  def test_the_surface_is_valid_and_addresses_every_registered_rpc_once
    doc = JSON.parse(surface_text)
    assert_empty OpenApi.problems(doc)
    assert_empty OpenApi.schema_problems(doc)
    rpcs = OpenApi.operations(doc["paths"]).map { |_, _, o| o["x-rpms"]["rpc"] }
    assert_equal(release[:doc]["rpcs"].map { |r| r["name"] }.sort, rpcs.sort)
    # Duplicate keys would collapse silently on parse, so count the operation lines in the raw text too.
    assert_equal rpcs.size, surface_text.scan(/^ {6}"(get|post|put|delete)": \{$/).size
    build = doc["x-rpms-build"]
    assert_equal [ release[:tag], release[:doc]["commit"] ], build.values_at("tag", "rpms_ops_commit")
    assert_equal({ "file" => "#{release[:tag]}-rpcs.json", "sha256" => release[:sha256], "schema" => release[:doc]["schema"] }, build["source"])
    assert_equal release[:surface].reach_counts, doc["x-rpms-counts"]["reach"]
  end

  def test_the_surface_counts_every_8994_parameter_rpcs_json_lists
    listed = release[:doc]["rpcs"].sum { |r| r["parameters"].count { |p| p["source"] == "8994" } }
    assert_equal listed, JSON.parse(surface_text)["x-rpms-counts"]["parameters"]["8994"]
  end

  def test_the_client_api_is_valid_and_places_every_rpc_backed_method
    doc = JSON.parse(api_text)
    assert_empty OpenApi.problems(doc)
    assert_empty OpenApi.schema_problems(doc)
    api = doc["x-rpms-api"]
    ids = OpenApi.operations(doc["paths"]).map { |_, _, o| o["operationId"] }
    placed = ids + api["folded"] + api["excluded"].values.flatten
    assert_equal methods["methods"].map { |m| "#{m['module'].delete_prefix('RpmsRpc::')}.#{m['method']}" }.sort, placed.sort
    assert_equal api["operations"], ids.size
    assert_equal methods["registry"], doc["x-rpms-build"]["tag"]
  end

  # Both documents are built on the release under test, so they name one build.
  def test_both_documents_name_the_same_build
    surface = JSON.parse(surface_text).dig("x-rpms-build", "tag")
    api = JSON.parse(api_text).dig("x-rpms-build", "tag")
    assert_equal surface, api, "the client API must be built on the surface's release"
  end

  def test_the_same_inputs_give_byte_identical_documents
    again = SURFACE.read(ReleaseUnderTest.inventory(self))
    assert_equal surface_text, OpenApi.pretty(OpenApi::Surface.document(again[:surface], build: SURFACE.build_provenance(again), gem: GEM))
    assert_equal api_text, OpenApi.pretty(OpenApi::ClientApi.document(JSON.parse(JSON.generate(methods)), gem: GEM))
  end

  def test_a_broken_document_fails_its_checks
    doc = JSON.parse(api_text)
    path, item = doc["paths"].first
    doc["paths"]["#{path}/x"] = item
    doc["paths"]["/bad"] = { "get" => { "operationId" => 7 } }
    assert(OpenApi.problems(doc).any? { |p| p.include?("operationId") })
    refute_empty OpenApi.schema_problems(doc)
    doc2 = JSON.parse(api_text)
    doc2["paths"]["/patients/{x}"] = doc2["paths"]["/patients/{dfn}"]
    assert(OpenApi.problems(doc2).any? { |p| p.include?("GET /patients/{} is 2 operations") })
  end
end
