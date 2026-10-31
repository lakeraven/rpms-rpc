# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/security_keys"
require "rpms_rpc/api/authentication"

# Authentication.held_keys(names) reports which named security keys the
# signed-on user holds, one ORWU NPHASKEY per name under OR CPRS GUI CHART
# (rpms-rpc#521). Read-only.
#
# Every live persona runs this spec. What a persona holds is the build's seed,
# not the gem's contract: an empty oracle list (PROV123 on the pinned build)
# is a valid outcome. The spec always checks that a synthetic unheld name
# answers [] (not nil); when the persona holds keys it also checks held plus
# unheld; when it holds none it cross-checks held_keys against has_security_key?
# on a few role-policy names from SecurityKeys::REGISTRY so a refusal is not
# read as "holds none".
class HeldKeysLiveTest < LiveSpec::Test
  CONTEXT = "CIAV VUECENTRIC"
  UNHELD = "LIVESPEC NO SUCH KEY"

  def test_held_keys_reports_a_held_key_and_an_unheld_key
    duz = client.duz
    refute_nil duz, "sign-on as #{persona} set no DUZ"

    held_names = client.with_context(CONTEXT) do
      RpmsRpc::Authentication.user_security_keys(duz)
    end

    unheld_only = RpmsRpc::Authentication.held_keys([ UNHELD ])
    assert_equal [], unheld_only,
                 "held_keys([#{UNHELD.inspect}]) must answer [] for an unheld key, not nil"

    if held_names.empty?
      probe = RpmsRpc::SecurityKeys::REGISTRY.values.first(3)
      result = RpmsRpc::Authentication.held_keys(probe)
      refute_nil result, "held_keys(#{probe.inspect}) must answer, not nil"

      client.with_context(CONTEXT) do
        probe.each do |name|
          expected = RpmsRpc::Authentication.has_security_key?(duz, name)
          if expected
            assert_includes result, name,
                            "held_keys must include #{name} when has_security_key? is true"
          else
            refute_includes result, name,
                            "held_keys must omit #{name} when has_security_key? is false"
          end
        end
      end

      puts "\n#{persona} holds no security keys on this build; held_keys([#{UNHELD.inspect}]) => []"
    else
      held = held_names.first
      result = RpmsRpc::Authentication.held_keys([ held, UNHELD ])
      assert_equal [ held ], result

      puts "\n#{persona} held_keys([#{held.inspect}, #{UNHELD.inspect}]) => #{result.inspect}"
    end
  end
end
