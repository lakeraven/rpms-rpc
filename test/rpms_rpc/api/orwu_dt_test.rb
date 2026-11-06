# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/retry_safety"
require "rpms_rpc/api/orwu"
require_relative "../stock_rpcs_test_helper"

# ORWU DT (DT^ORWU, ORWU.m:4-8) — FileMan date/time helper; rpms-rpc#420.
class OrwuDtTest < Minitest::Test
  include StockRpcsTestHelper

  Mod = RpmsRpc::Orwu

  def setup
    RpmsRpc.mock!
  end

  def teardown
    RpmsRpc.reset!
  end

  # DT(Y,X,%DT) normalizes midnight fragments (ORWU.m:6) then runs ^%DT (ORWU.m:7).
  def test_fileman_datetime_passes_x_and_dt_flag
    RpmsRpc.client.seed_scalar(:orwu_dt, "NOW", "3261104.120101")

    value = Mod.fileman_datetime("NOW")

    assert_equal "3261104.120101", value
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWU DT" }
    assert_equal [ "NOW", "TS" ], call[:params]
    assert_equal Mod::CONTEXT, call[:context]
  end

  def test_fileman_datetime_nil_when_rpc_unreachable
    assert_nil Mod.fileman_datetime("NOW")
  end

  def test_fileman_datetime_raises_on_broker_error
    erroring = Class.new do
      def with_context(*) = yield
      def call_rpc(*) = raise(RpmsRpc::Client::RpcError, "ORWU DT: error 4")
    end.new

    assert_raises(RpmsRpc::Client::RpcError) { Mod.fileman_datetime("NOW", client: erroring) }
  end

  def test_fileman_datetime_is_read_in_retry_safety
    assert_equal :read, RpmsRpc::RetrySafety.for(Mod, :fileman_datetime)
  end

  def test_context_is_ciav_vuecentric_on_the_pinned_build
    assert_includes pinned_rpc("ORWU DT").contexts, Mod::CONTEXT
  end

  def test_required_rpcs_lists_orwu_dt_under_orwu
    assert_required_rpc "ORWU DT", under: "RpmsRpc::Orwu"
  end
end
