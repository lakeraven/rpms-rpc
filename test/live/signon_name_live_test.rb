# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/ddr_fileman"

# CiaClient#authenticate names the signed-on user by the NEW PERSON name
# (#200 .01) the server answers in CIAVCXUS VIMINFO, for every user (#849).
# The sign-on greeting is not a name source: Kernel greets by NICK NAME
# (#200 field 13) when one is set (XUS1A.m:11, XUSRB5.m:101), and PROVIDER,TEST
# has NICK NAME TEST, so it is greeted "Good morning TEST". PROFILE,MD has no
# nickname and is greeted by the .01 name. Each run checks the name against
# FileMan's own record of the user, read with DDR GETS ENTRY DATA.
class SignonNameLiveTest < LiveSpec::Test
  runs_as "PROV123", "PMD123"

  def new_person_name(duz)
    reply = client.with_context("CIAV VUECENTRIC") do
      RpmsRpc::DdrFileman.gets_entry(file: "200", iens: "#{duz},", fields: ".01", flags: "I")
    end
    reply&.dig(:fields, ".01", :internal) || flunk("NEW PERSON #{duz} has no name")
  end

  def test_sign_on_names_the_user_by_their_new_person_name
    signed = RpmsRpc::CiaClient.new(host: ENV.fetch("BROKER_HOST"), port: Integer(ENV.fetch("BROKER_PORT")), timeout: 30)
    signed.connect
    result = signed.authenticate(ENV.fetch("RPMS_ACCESS"), ENV.fetch("RPMS_VERIFY"))

    name = new_person_name(result[:duz])
    assert_equal name, result[:user], "authenticate's user: is the NEW PERSON name (greeting #{result[:greeting].inspect})"
    assert_equal name, signed.signon_user
  ensure
    signed&.disconnect
  end
end
