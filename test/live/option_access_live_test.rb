# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/authentication"

# Authentication.option_access asks ORWU HAS OPTION ACCESS (HASOPTN^ORWU,
# $$ACCESS^XQCHK) for the signed-on user. On the pinned build every demo
# persona and the programmer are EHR users: CIAV VUECENTRIC, the option
# sign-on binds, is on their menus. An option that does not exist answers 0.
# The spec reads only.
class OptionAccessLiveTest < LiveSpec::Test
  def test_the_signed_on_user_may_run_the_ehr_option_and_not_one_that_does_not_exist
    allowed = RpmsRpc::Authentication.option_access([ "CIAV VUECENTRIC", "LIVESPEC NO SUCH OPTION" ])

    refute_nil allowed, "ORWU HAS OPTION ACCESS gave no 0/1 answer"
    assert_equal [ "CIAV VUECENTRIC" ], allowed
    puts "\n#{persona}: may run #{allowed.inspect}"
  end
end
