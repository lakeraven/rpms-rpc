# frozen_string_literal: true

require "minitest/autorun"
require_relative "captured_replies"
require_relative "../live/call_log"

# The live harness's call log (test/live/call_log.rb, rpms-rpc#818), on replies captured from a release:
# each call a spec sends is recorded once, with what the broker answered.
class LiveCallLogTest < Minitest::Test
  Log = LiveSpec::CallLog

  def teardown = Log.stop

  # A replay client answering the named captures, each under its RPC (the capture's, else the file's).
  def client(slug, *names)
    doc = CapturedReplies.file(slug)
    rpc = ->(n) { doc.fetch("captures").find { |c| c["name"] == n }.fetch("rpc", doc["rpc"]) }
    CapturedReplies::ReplayCiaClient.new(names.group_by(&rpc).transform_values { |ns| ns.map { |n| CapturedReplies.raw(slug, n) } })
  end

  def test_an_answered_call_is_recorded_once_though_call_rpc_reads_through_call_rpc_raw
    c = client("orwu-has-option-access", "option_access/2")
    Log.start
    c.call_rpc("ORWU HAS OPTION ACCESS", "CIAV VUECENTRIC")
    assert_equal [ { "rpc" => "ORWU HAS OPTION ACCESS", "outcome" => "answered" } ], Log.stop
  end

  # TIU AUTHORIZATION under AMHGRPC, which does not list it: the broker's refusal, as captured.
  def test_a_refusal_is_recorded_as_refused_with_the_brokers_words
    c = client("tiu-authorization", "refused")
    Log.start
    assert_raises(RpmsRpc::Client::RpcRefusedError) { c.call_rpc("TIU AUTHORIZATION", "1", "EDIT RECORD") }
    call = Log.stop.first
    assert_equal %w[TIU AUTHORIZATION refused], [ *call["rpc"].split, call["outcome"] ]
    assert_match(/Access denied for remote procedure: TIU AUTHORIZATION/, call["detail"])
  end

  # A spec that reads a raw CIA reply itself (call_rpc_raw): the flag byte says whether the broker refused it.
  def test_a_raw_cia_reply_is_read_by_its_flag_byte
    Log.start
    Log.around("TIU AUTHORIZATION", cia: true) { CapturedReplies.raw("tiu-authorization", "refused") }
    Log.around("TIU AUTHORIZATION", cia: true) { CapturedReplies.raw("tiu-authorization", "author_edit") }
    assert_equal %w[error answered], Log.stop.map { |c| c["outcome"] }
  end

  def test_nothing_is_recorded_while_the_log_is_closed
    c = client("orwu-has-option-access", "option_access/2")
    c.call_rpc("ORWU HAS OPTION ACCESS", "CIAV VUECENTRIC")
    assert_nil Log.calls
    assert_equal [], Log.stop
  end

  def test_an_xwb_client_answers_respond_to_as_before
    refute RpmsRpc::XwbClient.new(host: "127.0.0.1", port: 9100).respond_to?(:call_rpc_global_array)
  end
end
