# frozen_string_literal: true

require_relative "../live_helper"
require "rpms_rpc/api/ddr_fileman"

# A BMX sign-on by a user who does not hold the BMXRPC option is refused, and
# the client says so: ContextRefusedError, an AuthenticationError, as CIA
# raises when CIAV VUECENTRIC is refused (rpms-rpc#792), not ConnectionError.
#
# BMX direct mode checks every RPC against BMXRPC for the user
# (ADDCTXT^BMXMSEC, then $$CHK^XQCS). XUS AV CODE accepts the codes; the
# first RPC after it, XUS DIVISION GET, draws "User ... does not have access
# to option BMXRPC" in the security packet.
#
# Every seeded persona but PROVIDER,TEST holds BMXRPC through AKMOCORE, and
# PROVIDER,TEST holds it as a secondary menu from openrpms#1192 (its primary
# menu XUSERTOOLS does not carry it). So when PROVIDER,TEST holds it, the
# spec takes it away first: as the operator, over CIA, it deletes the BMXRPC
# SECONDARY MENU OPTIONS entry (#200.03) with DDR FILER, signs on over BMX as
# PROV123, and files the entry back. It WRITES, so it runs only against a
# disposable local container.
#
#   BROKER_PROTOCOL=bmx BROKER_PORT=<the image's 9101> CIA_PORT=<its 9100> rake test:live
class BmxSignonRefusedLiveTest < LiveSpec::Test
  runs_as :provider
  broker :bmx
  connect_only!
  writes!

  OPERATOR = [ "SYS123", "RPMS.000" ].freeze
  WITHOUT_BMXRPC = [ "PROV123", "PROV123!!" ].freeze
  PROVIDER_DUZ = "200" # PROVIDER,TEST, from KIDS transport 0019
  OPTION = "BMXRPC"

  def test_a_user_without_the_bmx_option_is_refused_at_sign_on
    held = bmxrpc_row
    remove_bmxrpc(held[:ien]) if held

    error = assert_raises(RpmsRpc::Client::ContextRefusedError) { client.authenticate(*WITHOUT_BMXRPC) }

    assert_kind_of RpmsRpc::Client::AuthenticationError, error, "a host that rescues AuthenticationError sees the refusal"
    assert_match(/does not have access to option #{OPTION}/, error.message)
    refute client.authenticated?, "the refused sign-on leaves no identity"
    assert_nil client.duz
  ensure
    restore_bmxrpc(held[:pointer]) if held
    @operator&.disconnect
  end

  private

  def operator
    @operator ||= RpmsRpc::CiaClient.new(host: ENV.fetch("BROKER_HOST"), port: cia_port, timeout: 30).tap do |c|
      c.connect
      c.authenticate(*OPERATOR)
    end
  end

  def cia_port
    Integer(ENV.fetch("CIA_PORT") { flunk "CIA_PORT is not set: the operator files the menu change over CIA (the image's 9100)" })
  end

  def as_operator(&)
    RpmsRpc.with_client(operator) { operator.with_context("CIAV VUECENTRIC", &) }
  end

  # PROVIDER,TEST's BMXRPC entry in #200.03, { ien:, pointer: } (the
  # subentry and its #19 pointer), or nil when it holds none.
  def bmxrpc_row
    listed = as_operator do
      RpmsRpc::DdrFileman.lister(file: "200.03", iens: ",#{PROVIDER_DUZ},", fields: ".01;.01I", flags: "P", max: "50")
    end
    flunk "DDR LISTER on PROVIDER,TEST's secondary menus failed: #{listed.inspect}" if listed.nil? || listed[:error]
    row = listed[:entries].find { |e| e[:pieces].first == OPTION }
    row && { ien: row[:ien], pointer: row[:pieces][1] }
  end

  def remove_bmxrpc(sub)
    filed = as_operator do
      RpmsRpc::DdrFileman.filer(mode: "EDIT", rows: [ { file: "200.03", field: ".01", iens: "#{sub},#{PROVIDER_DUZ},", value: "@" } ])
    end
    assert filed && filed[:success], "could not take #{OPTION} from PROVIDER,TEST: #{filed.inspect}"
    assert_nil bmxrpc_row, "PROVIDER,TEST still holds #{OPTION}"
  end

  # DDR FILER's ADD files internal values (UPDATE^DIE with no flags,
  # DDR3.m:15), so the option goes back as its #19 pointer, not its name.
  def restore_bmxrpc(pointer)
    return if bmxrpc_row

    filed = as_operator do
      RpmsRpc::DdrFileman.filer(mode: "ADD", rows: [ { file: "200.03", field: ".01", iens: "+1,#{PROVIDER_DUZ},", value: pointer } ])
    end
    assert filed && filed[:success], "could not give #{OPTION} back to PROVIDER,TEST: #{filed.inspect}"
    refute_nil bmxrpc_row, "PROVIDER,TEST does not list #{OPTION} again"
  end
end
