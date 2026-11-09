# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/progress_note"
require_relative "../captured_replies"

# rpms-rpc#614: SETTEXT^TIUSRVPT replaces an unsigned note's body for any
# signed-on user (TIUSRVPT.m:7-38 has no author check), and TIU LOCK RECORD is
# no ownership check. So ProgressNote.update_text asks TIU AUTHORIZATION
# (CANDO^TIUSRVA) for EDIT RECORD first, and sends TIU SET DOCUMENT TEXT only
# on its "1". Anything else sends nothing: "0^reason" and an empty reply
# return the failure hash, a refused call raises.
#
# Evidence: test/fixtures/captured_replies/tiu-authorization.yml, captured
# live on a note PROFILE,MD wrote: the author is allowed, PROFILE,RN is told
# "0^ You may not EDIT this UNSIGNED Progress Note." yet takes the lock.
class RpmsRpc::ProgressNoteUpdateTextAuthorizationTest < Minitest::Test
  PN = RpmsRpc::ProgressNote
  SLUG = "tiu-authorization"
  AUTH = "TIU AUTHORIZATION"
  SET = "TIU SET DOCUMENT TEXT"

  def teardown
    RpmsRpc.reset!
  end

  def capture(name) = CapturedReplies.raw(SLUG, name)
  def note = CapturedReplies.file(SLUG).fetch("captures").first.fetch("inputs").first

  def update_with(auth_reply, set_reply: capture("author_set_text"))
    client = CapturedReplies::ReplayCiaClient.new(AUTH => [ auth_reply ], SET => [ set_reply ])
    RpmsRpc.configure { |cfg| cfg.client = client }
    [ PN.update_text(note, "Synthetic replacement text."), client ]
  end

  def test_the_author_is_authorized_first_then_the_text_is_set
    result, client = update_with(capture("author_edit"))

    assert result[:success], result.inspect
    assert_equal [ AUTH, SET ], client.rpcs_called
    assert_equal [ note, PN::EDIT_RECORD ], client.calls.first[:params]
  end

  def test_another_user_is_refused_and_no_text_is_sent
    result, client = update_with(capture("other_user_edit"))

    refute result[:success]
    assert_equal [ AUTH ], client.rpcs_called, "TIU SET DOCUMENT TEXT must not be sent"
    assert_match(/not authorized/i, result[:error])
  end

  def test_a_note_that_does_not_exist_is_refused_without_sending_text
    result, client = update_with(capture("no_such_note"))

    refute result[:success]
    assert_equal [ AUTH ], client.rpcs_called
  end

  def test_an_empty_authorization_reply_is_refused_without_sending_text
    empty = capture("author_edit").byteslice(0, 2) # the captured echo and data ack, no answer
    result, client = update_with(empty)

    refute result[:success]
    assert_equal [ AUTH ], client.rpcs_called
  end

  def test_a_refused_authorization_call_raises_without_sending_text
    client = CapturedReplies::ReplayCiaClient.new(AUTH => [ capture("refused") ], SET => [ capture("author_set_text") ])
    RpmsRpc.configure { |cfg| cfg.client = client }

    assert_raises(RpmsRpc::Client::RpcError) { PN.update_text(note, "Synthetic replacement text.") }
    assert_equal [ AUTH ], client.rpcs_called, "a broker error raises, as one from SET does, and nothing is set"
  end

  def test_the_lock_is_no_ownership_check
    # Why update_text cannot lean on lock: the other user holds it.
    client = CapturedReplies::ReplayCiaClient.new("TIU LOCK RECORD" => [ capture("other_user_lock") ])
    RpmsRpc.configure { |cfg| cfg.client = client }

    assert PN.lock(note)
  end
end
