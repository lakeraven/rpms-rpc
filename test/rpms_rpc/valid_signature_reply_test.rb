# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/e_signature"
require_relative "captured_replies"

# rpms-rpc#601: ORWU VALIDSIG is the gate in front of ORWDX SEND and TIU SIGN
# RECORD, so its reply must be read fail-closed. VALIDSIG^ORWU answers one
# scalar, "1" or "0" (captured live: test/fixtures/captured_replies/orwu-validsig.yml).
# The gate accepts only a reply with exactly one data line, and that line "1".
#
# The ambiguous replies are the captured replies with a line added after
# them, read through CiaClient's own reply grammar: the server sends neither,
# and no container can be asked to, so they are built from the real bytes
# rather than written from scratch.
class RpmsRpc::ValidSignatureReplyTest < Minitest::Test
  SLUG = "orwu-validsig"
  PROFILE_MA_DUZ = "204" # the DUZ the capture signed on as (SEEDPERS USER row); validate does not send it

  def teardown
    RpmsRpc.reset!
  end

  def validate_against(raw)
    client = CapturedReplies::ReplayCiaClient.new("ORWU VALIDSIG" => [ raw ])
    RpmsRpc.configure { |cfg| cfg.client = client }
    RpmsRpc::ESignature.validate(PROFILE_MA_DUZ, "any code")
  end

  def accepted_raw = CapturedReplies.raw(SLUG, "stored_code")
  def refused_raw = CapturedReplies.raw(SLUG, "other_code")

  def test_the_captured_accept_reply_is_accepted
    assert validate_against(accepted_raw)
  end

  def test_the_captured_refuse_reply_is_refused
    refute validate_against(refused_raw)
  end

  def test_an_accept_line_followed_by_a_refuse_line_is_refused
    refute validate_against(accepted_raw + "\r\n0".b), "contradictory lines must not read as the first one"
  end

  def test_a_refuse_line_followed_by_an_accept_line_is_refused
    refute validate_against(refused_raw + "\r\n1".b)
  end

  def test_an_accept_line_followed_by_a_malformed_line_is_refused
    refute validate_against(accepted_raw + "\r\nnot a reply".b)
  end

  def test_two_accept_lines_are_refused
    refute validate_against(accepted_raw + "\r\n1".b), "exactly one data line, not one or more agreeing lines"
  end

  def test_a_trailing_line_break_after_the_accept_line_is_still_one_line
    assert validate_against(accepted_raw + "\r\n".b)
  end

  def test_line_for_returns_nil_for_more_than_one_data_line
    client = CapturedReplies::ReplayCiaClient.new("ORWU VALIDSIG" => [ accepted_raw + "\r\n0".b ])

    assert_nil RpmsRpc::ValidSignature.line_for("x", client: client)
  end
end
