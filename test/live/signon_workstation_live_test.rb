# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/ddr_fileman"

# CiaClient#authenticate tells RPMS who is calling: the workstation (AUTH's
# WID) and the address of the person signing on (WIP). RPMS writes the address
# to the Kernel sign-on log, SIGN-ON LOG (#3.081) field 11 IPV4 ADDRESS, which
# DDR LISTER reads in CIAV VUECENTRIC. Each run signs on from a fresh
# documentation address (RFC 5737), and finds it on a sign-on log entry for this
# persona. Signing on writes a log entry, as any sign-on does; it reads
# nothing else.
class SignonWorkstationLiveTest < LiveSpec::Test
  def test_the_sign_on_log_records_the_address_the_session_was_signed_on_from
    address = "198.51.100.#{rand(1..254)}"
    signed = RpmsRpc::CiaClient.new(host: ENV.fetch("BROKER_HOST"), port: Integer(ENV.fetch("BROKER_PORT")), timeout: 30)
    signed.connect
    result = signed.authenticate(ENV.fetch("RPMS_ACCESS"), ENV.fetch("RPMS_VERIFY"),
                                 workstation: "rpms-rpc live spec", workstation_ip: address)

    log = client.with_context("CIAV VUECENTRIC") do
      RpmsRpc::DdrFileman.lister(file: "3.081", fields: "@;.01I;11", flags: "IPB", max: 20)
    end
    refute_nil log, "DDR LISTER on the sign-on log gave no reply"
    refute log[:error], "DDR LISTER on the sign-on log answered with errors: #{log.inspect}"
    mine = log[:entries].find { |e| e[:pieces] == [ result[:duz].to_s, address ] }
    assert mine, "no sign-on log entry for DUZ #{result[:duz]} from #{address} among the newest 20: #{log[:entries].map { |e| e[:pieces] }.inspect}"
  ensure
    signed&.disconnect
  end
end
