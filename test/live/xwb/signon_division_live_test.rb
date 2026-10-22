# frozen_string_literal: true

require_relative "../live_helper"

# XWB sign-on binds the division, DUZ(2), the way the stock XWB client does
# (rpms-rpc#450, the twin of the CIA spec signon_division_live_test.rb): XUS
# DIVISION GET after XUS AV CODE, XUS DIVISION SET when a division is named or
# the user has several (Client#bind_division). BMX speaks the same RPCs.
#
# The server's DUZ(2) is read back with XUS GET USER INFO, whose fourth line is
# "DUZ(2)^station name" (USERINFO^XUSRB2, RET(3)). It is in XUS SIGNON, so it
# answers before any context is bound, for every persona.
#
# What a single-division build cannot show: DIVSET moving a session between two
# divisions of one user. The pinned build's personas have one each. It reads only.
module XwbSignonDivisionLive
  USER_INFO_DIVISION_LINE = 3

  def server_division(client)
    line = client.call_rpc_lines("XUS GET USER INFO")[USER_INFO_DIVISION_LINE].to_s
    ien = line.split("^", 2).first.to_s
    assert_match(/\A\d+\z/, ien, "XUS GET USER INFO line #{USER_INFO_DIVISION_LINE + 1} is not DUZ(2)^name: #{line.inspect}")
    ien.to_i
  end
end

class XwbSignonDivisionLiveTest < LiveSpec::Test
  include XwbSignonDivisionLive
  broker :xwb
  connect_only!

  def sign_on_as_persona(**)
    client.authenticate(ENV.fetch("RPMS_ACCESS"), ENV.fetch("RPMS_VERIFY"), **)
  end

  # No division named: the session acts in one of the user's divisions, and
  # the server's DUZ(2) is the one the client reports.
  def test_signon_binds_a_division_of_the_user
    result = sign_on_as_persona
    assert result[:success]
    refute_empty client.divisions, "#{persona} has no DIVISION (#200 field 16), so sign-on should have refused"
    assert_includes client.divisions, client.division
    assert_equal client.division[:ien], result[:division]
    assert_equal client.division[:ien], server_division(client),
      "the server's DUZ(2) is not the division the client says it bound"
    puts "\n#{persona}: division #{client.division.inspect}"
  end

  # Naming the user's division signs on in it, through XUS DIVISION SET.
  def test_naming_one_of_the_users_divisions_signs_on_in_it
    ien = sign_on_as_persona[:division]
    client.disconnect
    client.connect

    result = sign_on_as_persona(division: ien)
    assert result[:success]
    assert_equal ien, result[:division]
    assert_equal ien, server_division(client)
  end

  # A division the user lacks is refused and leaves the client signed off: by
  # the client's list check when DIVGET listed several, by DIVSET^XUSRB2 (which
  # looks the value up in the user's own DIVISION multiple) when DIVGET answered 0.
  def test_naming_a_division_the_user_lacks_fails_closed
    sign_on_as_persona
    foreign = client.divisions.map { |d| d[:ien] }.max + 1
    client.disconnect
    client.connect

    error = assert_raises(RpmsRpc::Client::AuthenticationError) { sign_on_as_persona(division: foreign) }
    # one division: DIVGET answered 0 and the server's DIVSET refuses it; several: the client's list check refuses it first
    assert_match(/not one of DUZ \d+'s divisions|XUS DIVISION SET \d+ answered \["0"\]/, error.message)
    refute client.authenticated?
    assert_nil client.duz
    assert_nil client.division
  end
end
