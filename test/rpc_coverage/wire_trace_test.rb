# frozen_string_literal: true

require "minitest/autorun"
$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "rpms_rpc/client"
require_relative "../../tools/rpc_coverage/wire_trace"

# rpc:live's wire trace (rpms-rpc#335 AC6): a transport error on either call path is evidence.
class RpcCoverageWireTraceTest < Minitest::Test
  class FakeClient
    def call_rpc_raw(_name, *_params) = raise(RpmsRpc::Client::RpcTimeoutError, "timed out after 30s")
    def call_rpc_global_array(_name, *_params) = raise(RpmsRpc::Client::RpcTimeoutError, "timed out after 30s")
  end
  FakeClient.prepend(RpcCoverage::WireTrace)

  def setup
    RpcCoverage::WireTrace.log.clear
  end

  def test_a_timeout_on_the_global_array_path_is_logged_as_a_transport_error
    assert_raises(RpmsRpc::Client::RpcTimeoutError) { FakeClient.new.call_rpc_global_array("AMHG GET VISITS", "x") }
    entry = RpcCoverage::WireTrace.log.last
    assert_equal "AMHG GET VISITS", entry[:rpc]
    assert_equal :transport_error, entry[:reply]
    assert_match(/RpcTimeoutError/, entry[:detail])
  end

  def test_a_timeout_on_the_plain_path_is_logged_as_a_transport_error
    assert_raises(RpmsRpc::Client::RpcTimeoutError) { FakeClient.new.call_rpc_raw("ORQQPL LIST", "1") }
    assert_equal :transport_error, RpcCoverage::WireTrace.log.last[:reply]
  end

  def test_reply_flag_bytes_classify_data_error_and_no_data
    assert_equal [ :data, 2 ], RpcCoverage::WireTrace.classify("5\x00ab")
    assert_equal :error, RpcCoverage::WireTrace.classify("5\x01denied").first
    assert_equal [ :no_data, 0 ], RpcCoverage::WireTrace.classify("5")
  end
end
