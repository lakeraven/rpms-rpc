# frozen_string_literal: true

require_relative "../live_helper"
require "rpms_rpc/api/authentication"

# RpmsRpc::Authentication.authenticate, end to end over XWB: XUS SIGNON SETUP,
# XUS AV CODE, then the reads a successful sign-on implies (XUS GET USER INFO,
# ORWU USERINFO). It cannot run over CIA, whose broker refuses SETUP and
# AV CODE once CIANBRPC AUTH has signed the session on (user_role_live_test.rb
# proves the user_type step there), so this spec is the XWB half of #236.
#
# What it proves, in one fresh session per persona:
#   * the sign-on succeeds with a positive DUZ;
#   * post_signon_message_count is RET(5) of VALIDAV (XUSRB.m:85-87): the
#     number of post-sign-on lines that follow it, RET(6..5+n), or 0 when the
#     site suppresses the message ($$SHOWPOST, XUSRB.m:87), in which case the
#     lines are still sent and the count says not to show them;
#   * user_type is the mapping of the USRCLS a direct ORWU USERINFO answers in
#     the same session, with no :user_type_error.
#
# The harness only connects (connect_only!): the sign-on under test is the
# spec's own. It reads only; it files nothing.
class AuthenticateXwbLiveTest < LiveSpec::Test
  broker :xwb
  connect_only!

  # Keeps the XUS AV CODE reply lines, so the count can be checked against
  # what the server actually sent.
  module AvCodeTap
    attr_reader :av_code_reply

    def call_rpc(name, *params)
      reply = super
      @av_code_reply = Array(reply) if name == "XUS AV CODE"
      reply
    end
  end

  def test_authenticate_signs_on_and_reports_the_message_count_and_user_class
    client.singleton_class.prepend(AvCodeTap)

    result = RpmsRpc::Authentication.authenticate(access_code: ENV.fetch("RPMS_ACCESS"),
                                                  verify_code: ENV.fetch("RPMS_VERIFY"))
    if result[:verify_needs_change]
      flunk "#{persona}'s verify code must be changed on this build before it can sign on. " \
            "This spec never changes codes: change it by hand, or use a pair that never expires."
    end
    assert_equal true, result[:success], "authenticate as #{persona} failed: #{result[:error].inspect}"
    assert_kind_of Integer, result[:duz]
    assert_operator result[:duz], :>, 0

    assert_message_count(result[:post_signon_message_count], client.av_code_reply)
    assert_user_type(result)
  end

  private

  def assert_message_count(count, reply)
    refute_nil reply, "the spec saw no XUS AV CODE reply"
    assert_kind_of Integer, count
    assert_operator count, :>=, 0
    assert_equal Integer(reply[5].to_s.strip), count, "post_signon_message_count is not RET(5) of the reply"

    following = reply.drop(6).size
    if count.positive?
      assert_equal count, following, "RET(5) counts the lines RET(6..5+n) that follow it (XUSRB.m:86)"
    end
    puts "\n#{persona}: post_signon_message_count #{count}, #{following} line(s) after RET(5)"
  end

  def assert_user_type(result)
    usrcls = Integer(Array(client.call_rpc("ORWU USERINFO")).first.to_s.split("^")[2])
  rescue RpmsRpc::Client::RpcError => e
    # The session cannot run ORWU USERINFO, so neither could authenticate:
    # the result must say so, never default a class.
    assert_nil result[:user_type]
    assert_includes result[:user_type_error].to_s, e.message,
                    "authenticate's user_type_error does not name the refusal the direct read got"
    skip_tracked("#393", "#{persona}'s XWB session cannot run ORWU USERINFO right after sign-on " \
                         "(#{e.message}), so authenticate reports user_type_error")
  else
    expected = RpmsRpc::Authentication.user_type_for(usrcls)
    refute_nil expected, "ORWU USERINFO answered USRCLS #{usrcls} for #{persona}, which ORWU.m:19 never returns"
    refute result.key?(:user_type_error), "authenticate reported #{result[:user_type_error].inspect}"
    assert_equal expected, result[:user_type],
                 "ORWU USERINFO says USRCLS #{usrcls} for #{persona}; authenticate said #{result[:user_type].inspect}"
    puts "#{persona}: DUZ #{result[:duz]}, USRCLS #{usrcls} -> user_type #{result[:user_type]}"
  end
end
