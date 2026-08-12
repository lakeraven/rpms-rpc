# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/version"
require "rpms_rpc/broker_factory"
# the factory requires these lazily; load them here so the constants exist for the assertions
require "rpms_rpc/xwb_client"
require "rpms_rpc/cia_broker_client"
require "rpms_rpc/bmx_client"

class RpmsRpc::BrokerFactoryTest < Minitest::Test
  def setup
    @prev_broker = ENV["VISTA_BROKER"]
    @prev_port = ENV["VISTA_RPC_PORT"]
    ENV.delete("VISTA_BROKER")
    ENV.delete("VISTA_RPC_PORT")
  end

  def teardown
    ENV["VISTA_BROKER"] = @prev_broker
    ENV["VISTA_RPC_PORT"] = @prev_port
  end

  def test_selects_the_client_for_each_broker
    assert_instance_of RpmsRpc::XwbClient, RpmsRpc.client_for(:xwb, host: "h")
    assert_instance_of RpmsRpc::CiaBrokerClient, RpmsRpc.client_for(:cia, host: "h")
    assert_instance_of RpmsRpc::BmxClient, RpmsRpc.client_for(:bmx, host: "h")
  end

  def test_accepts_aliases
    assert_instance_of RpmsRpc::XwbClient, RpmsRpc.client_for(:vista, host: "h")
    assert_instance_of RpmsRpc::XwbClient, RpmsRpc.client_for(:va, host: "h")
    assert_instance_of RpmsRpc::CiaBrokerClient, RpmsRpc.client_for(:rpms, host: "h")
    assert_instance_of RpmsRpc::CiaBrokerClient, RpmsRpc.client_for(:vuecentric, host: "h")
    assert_instance_of RpmsRpc::BmxClient, RpmsRpc.client_for(:bmxnet, host: "h")
  end

  def test_string_and_case_insensitive
    assert_instance_of RpmsRpc::CiaBrokerClient, RpmsRpc.client_for("CIA", host: "h")
  end

  def test_defaults_to_xwb_then_env
    assert_instance_of RpmsRpc::XwbClient, RpmsRpc.client_for(host: "h")
    ENV["VISTA_BROKER"] = "cia"
    assert_instance_of RpmsRpc::CiaBrokerClient, RpmsRpc.client_for(host: "h")
  end

  def test_passes_connection_options_through
    c = RpmsRpc.client_for(:cia, host: "example", port: 9100, timeout: 7)
    assert_equal "example", c.host
    assert_equal 9100, c.port
    assert_equal 7, c.timeout
  end

  def test_unknown_broker_raises
    assert_raises(ArgumentError) { RpmsRpc.client_for(:bogus) }
  end
end
