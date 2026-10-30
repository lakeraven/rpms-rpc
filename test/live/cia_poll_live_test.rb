# frozen_string_literal: true

require_relative "live_helper"

# CiaClient#poll and Authentication.timed_read on a real broker: the {CIA} poll action keeps a signed-on
# session open past the listener's idle cut (about 45 s), and a session that
# sends nothing for longer is closed. Read-only: polls change nothing in RPMS.
class CiaPollLiveTest < LiveSpec::Test
  def test_poll_returns_rpms_polling_interval_and_its_clock
    result = client.poll

    assert_operator result[:interval], :>, 0
    # RPMS's wall clock: a FileMan time carries no zone, and a container may run
    # in UTC while this host does not (cloud-rpms#151), so only the day is checked.
    assert_in_delta Time.now.to_f, result[:server_time].to_f, 86_400, "the server's clock, within a day of ours"
  end

  # How long RPMS lets this user sit idle: the limit a host stops polling at.
  def test_rpms_names_the_signed_on_users_idle_limit
    require "rpms_rpc/api/authentication"
    assert_operator RpmsRpc::Authentication.timed_read(client.duz).to_i, :>, 0
  end

  def test_a_polled_session_still_answers_after_the_idle_cut
    4.times do
      sleep 20
      client.poll
    end

    assert client.call_rpc("ORWU USERINFO"), "polled every 20 s for 80 s, the session still answers"
  end

  def test_a_session_that_sends_nothing_is_closed_by_the_broker
    sleep 70

    assert_raises(RpmsRpc::Client::ConnectionError) { client.call_rpc("ORWU USERINFO") }
  end
end
