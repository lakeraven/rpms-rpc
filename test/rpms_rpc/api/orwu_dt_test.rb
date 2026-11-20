# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/retry_safety"
require "rpms_rpc/api/orwu"
require_relative "../stock_rpcs_test_helper"
require_relative "../captured_replies"

# ORWU DT (DT^ORWU, ORWU.m:4-8) — FileMan date/time helper; rpms-rpc#420.
# The replies are test/fixtures/captured_replies/orwu-dt.yml, captured live,
# replayed through CiaClient's own reply grammar (rpms-rpc#620).
class OrwuDtTest < Minitest::Test
  include StockRpcsTestHelper

  Mod = RpmsRpc::Orwu
  SLUG = "orwu-dt"

  def teardown
    RpmsRpc.reset!
  end

  def replay(name)
    CapturedReplies::ReplayCiaClient.new("ORWU DT" => [ CapturedReplies.raw(SLUG, name) ])
  end

  # DT(Y,X,%DT) normalizes midnight fragments (ORWU.m:6) then runs ^%DT (ORWU.m:7).
  def test_fileman_datetime_passes_x_and_dt_flag_and_reads_the_server_now
    client = replay("now")

    value = Mod.fileman_datetime("NOW", client: client)

    assert_equal "3261109.023504", value
    assert_equal [ { rpc: "ORWU DT", params: [ "NOW", "TS" ] } ], client.calls,
                 "one call, X and %DT, on the CIA sign-on's own option (no rebind)"
    assert_equal Mod::CONTEXT, client.current_context
  end

  def test_fileman_datetime_reads_the_server_today_as_a_date
    assert_equal "3261109", Mod.fileman_datetime("T", client: replay("today"))
  end

  # ^%DT answers -1 for text that is not a date; that is not a datetime.
  def test_fileman_datetime_nil_when_the_server_cannot_read_the_date
    assert_nil Mod.fileman_datetime("NOTADATE", client: replay("not_a_date"))
  end

  # The broker's refusal (the call under an option that does not list ORWU DT)
  # is raised, not read as a nil date.
  def test_fileman_datetime_raises_the_broker_refusal
    error = assert_raises(RpmsRpc::Client::RpcRefusedError) { Mod.fileman_datetime("T", client: replay("refused")) }
    assert_match(/Access denied for remote procedure: ORWU DT/, error.message)
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
