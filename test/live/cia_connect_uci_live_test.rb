# frozen_string_literal: true

require_relative "live_helper"

# With RPMS_UCI unset, the connect sends an empty UCI and the broker runs the
# session in its own namespace (ACTC^CIANBACT, CIANBACT.m:9-11), so a client
# needs no UCI setting to reach a broker on either engine (rpms-rpc#572). The
# old default, "VEH,EXTERNAL", names a namespace a broker may not have, and
# one that does not have it hangs up on the connect.
class CiaConnectUciLiveTest < LiveSpec::Test
  connect_only!

  def test_an_unset_uci_connects_and_signs_on_in_the_brokers_namespace
    had, prev = ENV.key?("RPMS_UCI"), ENV["RPMS_UCI"]
    ENV.delete("RPMS_UCI")
    c = RpmsRpc::CiaClient.new(host: ENV.fetch("BROKER_HOST"), port: Integer(ENV.fetch("BROKER_PORT")))
    c.connect
    assert c.connected?, "the broker did not answer a connect with an empty UCI"

    result = c.authenticate(ENV.fetch("RPMS_ACCESS"), ENV.fetch("RPMS_VERIFY"))
    assert result[:success]
    assert_operator result[:duz], :>, 0, "sign-on in the broker's own namespace resolved no DUZ"
    puts "\n#{persona}: empty UCI connected and signed on as DUZ #{result[:duz]}"
  ensure
    c&.disconnect
    had ? ENV["RPMS_UCI"] = prev : ENV.delete("RPMS_UCI")
  end
end
