# frozen_string_literal: true

require_relative "live_helper"

# CIA sign-on binds the division, DUZ(2), explicitly (rpms-rpc#293), the way
# VueCentric does: CIANBRPC DIVGET straight after AUTH, CIANBRPC DIVSET when
# the division wanted is not the one DIVGET chose (CiaClient#bind_division).
#
# The server's DUZ(2) is read back with BEHOSICX SITEINFO, which answers for
# INST=+DUZ(2) and returns that IEN as its tenth line (SITEINFO^BEHOSICX,
# BEHOSICX.m:7,10). It is in CIAV VUECENTRIC, the option sign-on binds, so it
# answers for the least-privilege persona as well as the programmer.
#
# What a single-division build cannot show: DIVSET moving a session from one
# division to another, which needs a user with two DIVISION (#200 field 16)
# entries. The pinned build's personas have one each. It reads only.
module SignonDivisionLive
  SITE_IEN_LINE = 9

  def server_division(client)
    line = client.call_rpc("BEHOSICX SITEINFO")[SITE_IEN_LINE].to_s
    assert_match(/\A\d+\z/, line, "BEHOSICX SITEINFO line #{SITE_IEN_LINE + 1} is not an INSTITUTION IEN")
    line.to_i
  end
end

class SignonDivisionLiveTest < LiveSpec::Test
  include SignonDivisionLive

  # The harness signed on with no division named: a one-division user acts in
  # that division, and the server's DUZ(2) is the one the client reports.
  def test_signon_binds_the_users_one_division
    refute_empty client.divisions, "#{persona} has no DIVISION (#200 field 16), so sign-on should have refused"
    assert_equal 1, client.divisions.size, "#{persona} has several divisions; sign-on without division: should have refused"
    assert_equal client.divisions.first, client.division
    assert_equal client.division[:ien], server_division(client),
      "the server's DUZ(2) is not the division the client says it bound"
    puts "\n#{persona}: division #{client.division.inspect}"
  end
end

class SignonDivisionChoiceLiveTest < LiveSpec::Test
  include SignonDivisionLive
  connect_only!

  def sign_on_as_persona(**)
    client.authenticate(ENV.fetch("RPMS_ACCESS"), ENV.fetch("RPMS_VERIFY"), **)
  end

  # Naming the user's division signs on in it.
  def test_naming_one_of_the_users_divisions_signs_on_in_it
    probe = sign_on_as_persona
    ien = probe[:division]
    client.disconnect
    client.connect

    result = sign_on_as_persona(division: ien)
    assert result[:success]
    assert_equal ien, result[:division]
    assert_equal ien, server_division(client)
  end

  # CIANBRPC DIVSET accepts any number (DIVSET^CIANBRPC sets DUZ(2)=+DIV and
  # checks nothing), so naming a division the user may not act in must be
  # refused by the client, and leave it signed off.
  def test_naming_a_division_the_user_lacks_fails_closed
    sign_on_as_persona
    foreign = client.divisions.map { |d| d[:ien] }.max + 1
    client.disconnect
    client.connect

    error = assert_raises(RpmsRpc::Client::AuthenticationError) { sign_on_as_persona(division: foreign) }
    assert_match(/not one of DUZ \d+'s divisions/, error.message)
    refute client.authenticated?
    assert_nil client.duz
    assert_nil client.division
  end
end
