# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/authentication"
require_relative "../captured_replies"

# Authentication.option_access over ORWU HAS OPTION ACCESS (HASOPTN^ORWU).
# The replies are the build's (test/fixtures/captured_replies/orwu-has-option-access.yml):
# option_access run as PROFILE,MD and PROFILE,REG on a throwaway container,
# recorded as flows and replayed through CiaClient. The live spec is
# test/live/option_access_live_test.rb.
class AuthenticationOptionAccessTest < Minitest::Test
  SLUG = "orwu-has-option-access"

  def teardown
    RpmsRpc.reset!
  end

  def replay(script)
    client = CapturedReplies::ReplayCiaClient.new(script)
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def replay_flow(name) = replay(CapturedReplies.flow_script(SLUG, name))

  def sent(client) = client.calls.map { |c| [ c[:rpc], c[:params] ] }

  def test_answers_the_options_the_user_may_run_in_the_order_asked
    client = replay_flow("option_access")

    assert_equal [ "CIAV VUECENTRIC" ], RpmsRpc::Authentication.option_access([ "AGMENU", "CIAV VUECENTRIC", "NO SUCH OPTION" ])
    assert_equal CapturedReplies.flow_calls(SLUG, "option_access"), sent(client)
  end

  def test_may_run_none_is_empty_not_nil
    replay_flow("option_access_none")

    assert_equal [], RpmsRpc::Authentication.option_access([ "AGMENU" ])
  end

  # The build refuses the RPC from an option that does not carry it.
  def test_a_refused_call_is_could_not_ask
    replay_flow("option_access_refused")

    assert_nil RpmsRpc::Authentication.option_access([ "CIAV VUECENTRIC" ])
  end

  # A client mechanic no server produces on demand: an answer that is not 0 or
  # 1 (here an empty reply frame, written by hand) is could-not-ask, even when
  # the other answers are the build's.
  def test_an_answer_that_is_not_0_or_1_is_could_not_ask
    ciav = CapturedReplies.flow(SLUG, "option_access").find { |c| c["inputs"] == [ "CIAV VUECENTRIC" ] }
    replay("ORWU HAS OPTION ACCESS" => [ ciav.fetch("raw_return"), "5\x00" ])

    assert_nil RpmsRpc::Authentication.option_access([ "CIAV VUECENTRIC", "AGMENU" ])
  end

  def test_no_names_sends_nothing
    client = replay({})

    assert_equal [], RpmsRpc::Authentication.option_access([ "", nil ])
    assert_empty client.calls
  end
end
