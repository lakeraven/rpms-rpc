# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "rpms_rpc"
require_relative "../../tools/api_coverage/api_coverage"

# lib/rpms_rpc/required_rpcs.json, the list client.compatibility checks a server against
# (rpms-rpc#366), is generated: it must equal what `rake rpc:required_rpcs` writes from lib/ now,
# so a method that starts or stops sending an RPC cannot ship with a stale list.
class RequiredRpcsTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def report
    @report ||= ApiCoverage.build(ROOT)
  end

  def test_the_committed_list_is_what_the_api_sends_now
    generated = ApiCoverage.required_rpcs_json(ApiCoverage.required_rpcs(report[:entries], build: report[:registry_tag], root: ROOT))
    assert generated == File.read(RpmsRpc::Compatibility::REQUIRED_PATH),
           "lib/rpms_rpc/required_rpcs.json is stale: run `bundle exec rake rpc:required_rpcs` and commit it"
  end

  def test_session_required_rpcs_are_viminfo_only
    committed = JSON.parse(File.read(RpmsRpc::Compatibility::REQUIRED_PATH))
    session_rpcs = committed.fetch("modules").fetch("RpmsRpc::Session")

    refute_includes session_rpcs, "CIAVMCFG GETREG"
    assert_equal [ "CIAVCXUS VIMINFO" ], session_rpcs
  end

  def test_groups_by_module_and_leaves_out_modules_that_send_nothing
    entries = [
      { module: "RpmsRpc::B", rpcs: [ { name: "Y" }, { name: "X" } ] },
      { module: "RpmsRpc::B", rpcs: [ { name: "X" } ] },
      { module: "RpmsRpc::A", rpcs: [ { name: "Z" } ] },
      { module: "RpmsRpc::Session", rpcs: [] }
    ]
    doc = ApiCoverage.required_rpcs(entries, build: "t")
    assert_equal({ "RpmsRpc::A" => [ "Z" ], "RpmsRpc::B" => %w[X Y] }, doc.fetch("modules"))
    assert_equal %w[X Y Z], doc.fetch("rpcs").keys
  end

  # The contract the openrpms release gate reads (rpms-rpc#724): one entry per RPC a public method
  # sends, naming every method that sends it, whether each is a read (lib/rpms_rpc/retry_safety.yml),
  # and the captured replies its parser is tested against. Asserted on the committed file, built
  # from lib/ and the real captures in test/fixtures.
  def test_the_contract_names_every_rpc_the_modules_send
    committed = JSON.parse(File.read(RpmsRpc::Compatibility::REQUIRED_PATH))
    assert_equal "rpms-rpc-contract.v1", committed.fetch("contract")
    sent = committed.fetch("modules").values.flatten.uniq.sort
    assert_equal sent, committed.fetch("rpcs").keys
    committed.fetch("rpcs").each do |name, e|
      refute_empty e.fetch("methods"), "#{name} names no method that sends it"
      e.fetch("methods").each_value do |access|
        assert_includes %w[read idempotent_write non_idempotent_write unclassified], access, name
      end
      e.fetch("replies").each { |f| assert File.file?(File.join(ROOT, f)), "#{name}: #{f} is not a file" }
    end
  end

  def test_an_rpc_points_at_the_replies_captured_for_it
    rpcs = JSON.parse(File.read(RpmsRpc::Compatibility::REQUIRED_PATH)).fetch("rpcs")
    allergen = rpcs.fetch("ORWDAL32 ALLERGY MATCH")
    assert_equal({ "RpmsRpc::Allergen.search" => "read" }, allergen.fetch("methods"))
    assert_equal [ "test/fixtures/captured_replies/allergen.yml" ], allergen.fetch("replies")
    # A capture inside another RPC's flow file counts for the RPC it sent.
    assert_includes rpcs.fetch("ORQQAL LIST").fetch("replies"), "test/fixtures/captured_replies/allergy-save.yml"
    # A wire capture counts too.
    assert_includes rpcs.fetch("BGOVMSR GET").fetch("replies"), "test/fixtures/wire_captures/bgovmsr-get.yml"
  end
end
