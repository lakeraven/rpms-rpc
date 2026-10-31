# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/authentication"

# Authentication.held_keys(names) reports which named security keys the
# signed-on user holds, one ORWU NPHASKEY per name under OR CPRS GUI CHART
# (rpms-rpc#521). Read-only.
class HeldKeysLiveTest < LiveSpec::Test
  CONTEXT = "CIAV VUECENTRIC"
  UNHELD = "LIVESPEC NO SUCH KEY"

  def test_held_keys_reports_a_held_key_and_an_unheld_key
    duz = client.duz
    refute_nil duz, "sign-on as #{persona} set no DUZ"

    held_names = client.with_context(CONTEXT) do
      RpmsRpc::Authentication.user_security_keys(duz)
    end
    if held_names.empty?
      flunk "#{persona} holds no security keys on this build; use a persona that holds at least one"
    end

    held = held_names.first
    result = RpmsRpc::Authentication.held_keys([ held, UNHELD ])

    assert_equal [ held ], result
    puts "\n#{persona} held_keys([#{held.inspect}, #{UNHELD.inspect}]) => #{result.inspect}"
  end
end
