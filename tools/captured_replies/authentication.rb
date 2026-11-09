# frozen_string_literal: true

require "rpms_rpc/api/authentication"

# The sign-on conversations RpmsRpc::Authentication has with the build, and the
# reads its user-class and security-key methods make. Sign-on (XUS SIGNON
# SETUP, XUS AV CODE, XUS CVC) runs over BMX as flows: the CIA broker refuses
# those RPCs once CIANBRPC AUTH has signed a session on. The reads run over
# CIA as each persona. rpms-rpc#619.
Auth = RpmsRpc::Authentication

CAPTURE = {
  rpc: "XUS AV CODE", entry_point: "VALIDAV^XUSRB",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair; DUZ 206)",
  access: "PMD123", verify: "PMD123!!",
  personas: {
    sched: { access: "PSCH123", verify: "PSCH123!!", signed_on_as: "PROFILE,SCHED (PSCH123, a published demo pair; DUZ 208)" },
    rn: { access: "PRN123", verify: "PRN123!!", signed_on_as: "PROFILE,RN (PRN123, a published demo pair)" },
    reg: { access: "PREG123", verify: "PREG123!!", signed_on_as: "PROFILE,REG (PREG123, a published demo pair; DUZ 207)" }
  },
  note: "Run on a throwaway container. The access/verify pair and the verify codes cross the wire XWB-encrypted " \
        "and are withheld. The last flow changes PROFILE,RN's verify code on that container only.",
  calls: [
    { name: "userinfo_md", rpc: "ORWU USERINFO", inputs: [], about: "PROFILE,MD's user info: USRCLS 3, DTIME 9999" },
    { name: "userinfo_sched", as: :sched, rpc: "ORWU USERINFO", inputs: [], about: "PROFILE,SCHED's user info" },
    { name: "userinfo_rn", as: :rn, rpc: "ORWU USERINFO", inputs: [], about: "PROFILE,RN's user info" },
    { name: "nphaskey_held", rpc: "ORWU NPHASKEY", inputs: [ "206", "ORES" ], about: "does DUZ 206 hold ORES" },
    { name: "nphaskey_unheld", rpc: "ORWU NPHASKEY", inputs: [ "206", "XUPROG" ], about: "does DUZ 206 hold XUPROG" },
    { name: "nphaskey_refused", as: :reg, context: "AGGRPC", rpc: "ORWU NPHASKEY", inputs: [ "207", "ORES" ],
      expect_error: true, about: "ORWU NPHASKEY asked in AGGRPC, an option that does not carry it" }
  ],
  flows: {
    "signon" => { broker: :bmx, withhold: [ "XUS AV CODE" ],
                  about: "authenticate as PROFILE,MD, then bind CIAV VUECENTRIC and read the user class",
                  run: lambda {
                    Auth.authenticate(access_code: " pmd123 ", verify_code: " pmd123!! ")
                    RpmsRpc.client.create_context("CIAV VUECENTRIC")
                    Auth.user_type(206)
                  } },
    "signon_unknown" => { broker: :bmx, withhold: [ "XUS AV CODE" ],
                          about: "authenticate with a pair no user holds",
                          run: -> { Auth.authenticate(access_code: "NOSUCH", verify_code: "USER1") } },
    "second_signon" => { broker: :bmx, withhold: [ "XUS AV CODE" ],
                         about: "authenticate as PROFILE,SCHED, then again on the same session with a wrong verify code",
                         run: lambda {
                           Auth.authenticate(access_code: "PSCH123", verify_code: "PSCH123!!")
                           begin
                             Auth.authenticate(access_code: "PSCH123", verify_code: "WRONG123")
                           rescue RpmsRpc::Client::RpcError
                             nil
                           end
                         } },
    "cvc_wrong_old" => { broker: :bmx, withhold: [ "XUS AV CODE", "XUS CVC" ],
                         about: "as PROFILE,RN, change the verify code giving a current code that is not theirs",
                         run: lambda {
                           Auth.authenticate(access_code: "PRN123", verify_code: "PRN123!!")
                           Auth.change_verify_code(old_verify_code: "WRONGOLD1!", new_verify_code: "QZX456!!WV",
                                                   confirm_verify_code: "QZX456!!WV")
                         } },
    "cvc" => { broker: :bmx, withhold: [ "XUS AV CODE", "XUS CVC" ],
               about: "as PROFILE,RN, change the verify code",
               run: lambda {
                 Auth.authenticate(access_code: "PRN123", verify_code: "PRN123!!")
                 Auth.change_verify_code(old_verify_code: "PRN123!!", new_verify_code: "QZX456!!WV",
                                         confirm_verify_code: "QZX456!!WV")
               } }
  }
}.freeze
