# frozen_string_literal: true

require_relative "live_helper"

# A user RPMS accepts but does not let into CIAV VUECENTRIC is told so
# (rpms-rpc#501). CIANBRPC AUTH takes their codes; CIAVCXUS VIMINFO, the identity
# read that follows it, is refused, because the option is not on their menus.
# PROFILE,BILL is that user on the build: a terminal user, the one SEEDPERS
# persona without CIAV VUECENTRIC. Sign-on still fails closed.
class SignonContextRefusedLiveTest < LiveSpec::Test
  connect_only!

  TERMINAL_ONLY = [ "PBIL123", "PBIL123!!" ].freeze
  HOLDS_THE_OPTION = [ "PMD123", "PMD123!!" ].freeze

  def test_valid_codes_without_the_option_are_told_that_and_stay_signed_out
    error = assert_raises(RpmsRpc::Client::ContextRefusedError) { client.authenticate(*TERMINAL_ONLY) }

    assert_kind_of RpmsRpc::Client::AuthenticationError, error, "a host that rescues AuthenticationError still fails closed"
    assert_match(/may not use CIAV VUECENTRIC/, error.message)
    refute client.authenticated?, "the session is left signed out"
  end

  def test_a_user_who_holds_the_option_signs_on
    result = client.authenticate(*HOLDS_THE_OPTION)

    assert result[:success]
    assert client.authenticated?
  end
end
