# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/mock_client"

# Authentication.option_access over ORWU HAS OPTION ACCESS (HASOPTN^ORWU).
# Replies as a fresh rpms-ydb e9b78c8 sent them to PMD123: ["1"] for CIAV
# VUECENTRIC, ["0"] for an option off the user's menus or not on file.
class AuthenticationOptionAccessTest < Minitest::Test
  def teardown
    RpmsRpc.reset!
  end

  def seed(answers)
    RpmsRpc.mock! { |m| answers.each { |option, lines| m.seed_raw_lines(:user_option_access, option, lines) } }
  end

  def test_answers_the_options_the_user_may_run_in_the_order_asked
    seed("CIAV VUECENTRIC" => [ "1" ], "AGMENU" => [ "0" ], "NO SUCH OPTION" => [ "0" ])

    assert_equal [ "CIAV VUECENTRIC" ], RpmsRpc::Authentication.option_access([ "AGMENU", "CIAV VUECENTRIC", "NO SUCH OPTION" ])
    assert_equal %w[AGMENU CIAV\ VUECENTRIC NO\ SUCH\ OPTION], RpmsRpc.client.received_calls.map { |c| c[:params].first }
  end

  def test_may_run_none_is_empty_not_nil
    seed("AGMENU" => [ "0" ])

    assert_equal [], RpmsRpc::Authentication.option_access([ "AGMENU" ])
  end

  def test_an_answer_that_is_not_0_or_1_is_could_not_ask
    seed("CIAV VUECENTRIC" => [ "1" ], "AGMENU" => [])

    assert_nil RpmsRpc::Authentication.option_access([ "CIAV VUECENTRIC", "AGMENU" ])
  end

  def test_a_refused_call_is_could_not_ask
    client = Object.new
    def client.call_rpc(*) = raise(RpmsRpc::Client::RpcError, "Remote Procedure 'ORWU HAS OPTION ACCESS' is not registered")
    RpmsRpc.configure { |c| c.client = client }

    assert_nil RpmsRpc::Authentication.option_access([ "CIAV VUECENTRIC" ])
  end

  def test_no_names_sends_nothing
    seed({})

    assert_equal [], RpmsRpc::Authentication.option_access([ "", nil ])
    assert_empty RpmsRpc.client.received_calls
  end
end
