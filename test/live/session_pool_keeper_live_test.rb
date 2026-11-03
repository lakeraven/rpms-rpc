# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/session_pool"

# SessionPool's keeper on a real broker: each pooled session stays open as
# long as its own user may sit idle, and ends after. The CIA listener ends a
# session that sends nothing for about 45 s, so a session kept past that,
# and still answering as its user, was kept by the keeper's polls; the other
# session, whose limit passed, is released and disconnected. Two demo
# personas from the build's published seed pairs sign on; it reads only.
# Runs for about 75 seconds.
class SessionPoolKeeperLiveTest < LiveSpec::Test
  PAIRS = [ [ "PSCH123", "PSCH123!!" ], [ "PREG123", "PREG123!!" ] ].freeze
  KEPT_FOR = 75

  def signed_on(pair)
    c = RpmsRpc::CiaClient.new(host: ENV.fetch("BROKER_HOST"), port: Integer(ENV.fetch("BROKER_PORT")), timeout: 30)
    c.connect
    c.authenticate(*pair)
    c
  end

  def answers_as(conn)
    Array(RpmsRpc.with_client(conn) { RpmsRpc.client.call_rpc("CIAVCXUS VIMINFO") }).first.to_s.split("^").first.to_s.strip
  end

  def test_each_session_is_kept_open_for_its_own_user_and_no_longer
    pool = RpmsRpc::SessionPool.new(max_sessions: 2, build: ->(_) { raise "sign in again" })
    kept = signed_on(PAIRS[0])
    ended = signed_on(PAIRS[1])
    pool.adopt("kept", kept)
    pool.adopt("ended", ended)
    pool.touch("kept", idle_for: 600)
    pool.touch("ended", idle_for: 5)

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + KEPT_FOR
    sleep [ pool.keep_alive_tick, 5 ].min while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline

    refute pool.include?("ended"), "the session whose limit passed is still pooled"
    refute ended.connected?, "the session whose limit passed is still connected"
    assert pool.include?("kept")
    assert_equal kept.duz, answers_as(kept), "after #{KEPT_FOR} s idle the kept session no longer answers as its user"
  ensure
    pool&.release("kept")
    pool&.release("ended")
  end
end
