# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/cia_client"
require "rpms_rpc/xwb_client"
require "rpms_rpc/bmx_client"
require "rpms_rpc/compatibility"

# client.compatibility (rpms-rpc#366): which RPCs this release sends that the server does not
# serve, asked once after sign-on, without running them. Nothing here reaches a broker: each
# client's call_rpc answers from a table, and records what it was asked.
class RpmsRpc::CompatibilityTest < Minitest::Test
  Compatibility = RpmsRpc::Compatibility

  REQUIRED = {
    "build" => "bcer-test",
    "modules" => {
      "RpmsRpc::Patient" => [ "ORWPT ID INFO", "ORWPT SELECT" ],
      "RpmsRpc::Referral" => [ "BMC ADD REFERRAL", "ORWPT SELECT" ],
      "RpmsRpc::Vital" => [ "ORQQVI VITALS" ]
    }
  }.freeze

  # A signed-on client whose call_rpc answers from `replies` (name => lines or a proc of params).
  module Canned
    attr_reader :calls

    def setup_canned(replies)
      @replies = replies
      @calls = []
      set_authenticated(42)
      self
    end

    def call_rpc(name, *params)
      @calls << [ name, *params ]
      reply = @replies.fetch(name) { raise RpmsRpc::Client::RpcNotAvailableError, "Unknown remote procedure: #{name}" }
      reply.respond_to?(:call) ? reply.call(*params) : reply
    end
  end

  def cia(registry)
    RpmsRpc::CiaClient.new(host: "127.0.0.1", port: 9100).extend(Canned).setup_canned("CIANBRPC GETRPCS" => registry)
  end

  def xwb(served)
    answer = ->(name, _use) { [ served.include?(name) ? "1" : "0" ] }
    RpmsRpc::XwbClient.new(host: "127.0.0.1", port: 9100).extend(Canned).setup_canned("XWB IS RPC AVAILABLE" => answer)
  end

  def every_required = REQUIRED["modules"].values.flatten.uniq

  # --- the release's list ----------------------------------------------------------------------

  def test_the_shipped_list_names_a_build_and_rpcs_per_api_module
    required = Compatibility.required
    refute_empty required.fetch("build")
    refute_empty required.fetch("modules")
    required["modules"].each do |mod, names|
      assert_match(/\ARpmsRpc::/, mod)
      refute_empty names, "#{mod} lists no RPCs"
      assert_equal names.uniq.sort, names, "#{mod}: names are sorted and unique"
    end
  end

  def test_the_shipped_list_is_in_the_gem
    spec = Gem::Specification.load(File.expand_path("../../rpms-rpc.gemspec", __dir__))
    assert_includes spec.files, "lib/rpms_rpc/required_rpcs.json"
  end

  # --- CIA: one registry read ------------------------------------------------------------------

  def test_cia_reports_nothing_missing_when_the_registry_holds_every_rpc
    client = cia(every_required + [ "XUS SIGNON SETUP" ])
    report = Compatibility.check(client, required: REQUIRED)

    assert_predicate report, :ok?
    assert_empty report.missing
    assert_equal "bcer-test", report.build
    assert_match(/serves every RPC .* \(4 RPCs, derived on bcer-test\)/, report.to_s)
  end

  def test_cia_groups_the_missing_rpcs_by_api_module
    client = cia([ "ORWPT ID INFO", "BMC ADD REFERRAL", "ORQQVI VITALS" ])
    report = Compatibility.check(client, required: REQUIRED)

    refute_predicate report, :ok?
    assert_equal({ "RpmsRpc::Patient" => [ "ORWPT SELECT" ], "RpmsRpc::Referral" => [ "ORWPT SELECT" ] }, report.missing)
    assert_equal [ "ORWPT SELECT" ], report.missing_rpcs
    assert_match(/does not serve 1 of the 4 RPCs/, report.to_s)
    assert_match(/RpmsRpc::Referral: ORWPT SELECT/, report.to_s)
  end

  def test_cia_asks_once_whatever_the_number_of_rpcs
    client = cia(every_required)
    Compatibility.check(client, required: REQUIRED)

    assert_equal [ [ "CIANBRPC GETRPCS" ] ], client.calls
  end

  def test_cia_an_empty_registry_is_a_failed_read_not_everything_missing
    err = assert_raises(RpmsRpc::Client::RpcError) { Compatibility.check(cia([ "", " " ]), required: REQUIRED) }
    assert_match(/CIANBRPC GETRPCS answered no RPC names/, err.message)
  end

  def test_cia_a_broker_that_refuses_the_read_raises_its_typed_error
    client = RpmsRpc::CiaClient.new(host: "127.0.0.1", port: 9100).extend(Canned).setup_canned({})
    assert_raises(RpmsRpc::Client::RpcNotAvailableError) { Compatibility.check(client, required: REQUIRED) }
  end

  # --- XWB: one XWB IS RPC AVAILABLE per RPC ---------------------------------------------------

  def test_xwb_asks_each_rpc_once_for_local_use
    client = xwb(every_required - [ "ORQQVI VITALS" ])
    report = Compatibility.check(client, required: REQUIRED)

    assert_equal({ "RpmsRpc::Vital" => [ "ORQQVI VITALS" ] }, report.missing)
    assert_equal every_required.sort.map { |n| [ "XWB IS RPC AVAILABLE", n, "L" ] }, client.calls
  end

  def test_xwb_an_answer_other_than_1_or_0_raises
    client = RpmsRpc::XwbClient.new(host: "127.0.0.1", port: 9100).extend(Canned).setup_canned("XWB IS RPC AVAILABLE" => [ "" ])
    err = assert_raises(RpmsRpc::Client::RpcError) { Compatibility.check(client, required: REQUIRED) }
    assert_match(/expected 1 or 0, got ""/, err.message)
  end

  # --- the host's choices ----------------------------------------------------------------------

  def test_strict_raises_naming_the_missing_rpcs
    err = assert_raises(Compatibility::MissingRpcsError) do
      Compatibility.check(cia([ "ORWPT SELECT" ]), strict: true, required: REQUIRED)
    end
    assert_kind_of RpmsRpc::Error, err
    assert_equal %w[BMC\ ADD\ REFERRAL ORQQVI\ VITALS ORWPT\ ID\ INFO], err.report.missing_rpcs
    assert_match(/RpmsRpc::Vital: ORQQVI VITALS/, err.message)
  end

  def test_strict_returns_the_report_when_nothing_is_missing
    assert_predicate Compatibility.check(cia(every_required), strict: true, required: REQUIRED), :ok?
  end

  def test_client_compatibility_checks_this_releases_list
    names = Compatibility.required["modules"].values.flatten.uniq
    report = cia(names).compatibility

    assert_predicate report, :ok?
    assert_equal Compatibility.required["build"], report.build
  end

  def test_it_runs_only_after_sign_on
    client = RpmsRpc::CiaClient.new(host: "127.0.0.1", port: 9100)
    err = assert_raises(RpmsRpc::Client::AuthenticationError) { client.compatibility }
    assert_match(/sign on first/, err.message)
  end

  def test_a_broker_without_an_availability_rpc_says_so
    client = RpmsRpc::BmxClient.new(host: "127.0.0.1", port: 9101)
    client.set_authenticated(42)
    err = assert_raises(RpmsRpc::Error) { client.compatibility }
    assert_match(/BmxClient cannot ask its server which RPCs it serves/, err.message)
  end
end
