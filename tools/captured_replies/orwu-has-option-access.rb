# frozen_string_literal: true

require "rpms_rpc/api/authentication"

# The ORWU HAS OPTION ACCESS conversations RpmsRpc::Authentication.option_access
# has with the build, recorded as flows: PROFILE,MD asking about an option on
# their menus, one off them and one not on file; then PROFILE,REG asking from
# AGGRPC, an option that does not carry the RPC. rpms-rpc#619.
Auth = RpmsRpc::Authentication

CAPTURE = {
  rpc: "ORWU HAS OPTION ACCESS", entry_point: "HASOPTN^ORWU",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair; DUZ 206)",
  access: "PMD123", verify: "PMD123!!",
  personas: {
    reg: { access: "PREG123", verify: "PREG123!!", signed_on_as: "PROFILE,REG (PREG123, a published demo pair; DUZ 207)" }
  },
  note: "Run on a throwaway container; reads only.",
  flows: {
    "option_access" => {
      about: "option_access for AGMENU (off PROFILE,MD's menus), CIAV VUECENTRIC and an option not on file",
      run: -> { Auth.option_access([ "AGMENU", "CIAV VUECENTRIC", "NO SUCH OPTION" ]) }
    },
    "option_access_none" => {
      about: "option_access for AGMENU alone",
      run: -> { Auth.option_access([ "AGMENU" ]) }
    },
    "option_access_refused" => {
      as: :reg,
      about: "option_access asked with AGGRPC bound, an option that does not carry ORWU HAS OPTION ACCESS",
      run: lambda {
        RpmsRpc.client.create_context("AGGRPC")
        Auth.option_access([ "CIAV VUECENTRIC" ])
      }
    }
  }
}.freeze
