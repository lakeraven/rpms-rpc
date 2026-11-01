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
    generated = ApiCoverage.required_rpcs_json(ApiCoverage.required_rpcs(report[:entries], build: report[:registry_tag]))
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
    assert_equal({ "build" => "t", "modules" => { "RpmsRpc::A" => [ "Z" ], "RpmsRpc::B" => %w[X Y] } },
                 ApiCoverage.required_rpcs(entries, build: "t"))
  end
end
