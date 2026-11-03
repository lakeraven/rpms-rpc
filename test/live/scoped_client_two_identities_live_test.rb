# frozen_string_literal: true

require_relative "live_helper"

# Two users, each on their own signed-on connection, with calls scoped by
# RpmsRpc.with_client (lakeraven-ehr ADR 0011, as amended): every RPC in a
# scope runs as that scope's user, whichever signed on last. The user an RPC
# ran as is read with CIAVCXUS VIMINFO, which answers for the connection's own
# signed-on user (piece 1, the DUZ). The second connection signs on as another
# demo persona from the build's published seed pairs. It reads only.
class ScopedClientTwoIdentitiesLiveTest < LiveSpec::Test
  OTHER_PERSONA = { "PSCH123" => [ "PREG123", "PREG123!!" ] }.freeze
  DEFAULT_OTHER = [ "PSCH123", "PSCH123!!" ].freeze

  def other_pair = OTHER_PERSONA.fetch(ENV.fetch("RPMS_ACCESS"), DEFAULT_OTHER)

  def connection_duz(conn) = Array(RpmsRpc.with_client(conn) { RpmsRpc.client.call_rpc("CIAVCXUS VIMINFO") }).first.to_s.split("^").first.to_s.strip

  def test_each_scoped_call_runs_as_its_own_connections_user
    first = client # signed on by the harness as the run's persona
    second = RpmsRpc::CiaClient.new(host: ENV.fetch("BROKER_HOST"), port: Integer(ENV.fetch("BROKER_PORT")), timeout: 30)
    second.connect
    second.authenticate(*other_pair) # signs on AFTER the first
    refute_equal first.duz, second.duz, "the two personas are different users"

    3.times do
      assert_equal first.duz, connection_duz(first), "a call scoped to the first connection ran as another user"
      assert_equal second.duz, connection_duz(second), "a call scoped to the second connection ran as another user"
    end
  ensure
    second&.disconnect
  end
end
