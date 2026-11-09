# frozen_string_literal: true

# The reads RpmsRpc::UserManagement makes: ORWU NEWPERS for search, and
# XUS GET USER INFO with ORWU USERINFO for find. rpms-rpc#621.
CAPTURE = {
  rpc: "ORWU NEWPERS", entry_point: "NEWPERS^ORWU",
  signed_on_as: "SYS123 (the build's operator, MANAGER,SYSTEM)",
  access: "SYS123", verify: "RPMS.000",
  note: "XUS GET USER INFO is refused to the clinical personas under CIAV VUECENTRIC, so find is captured as the operator. Nothing is filed.",
  calls: [
    { name: "newpers_pro", inputs: [ "PRO", "1" ], about: "users whose names follow PRO, walking forward" },
    { name: "user_info", rpc: "XUS GET USER INFO", inputs: [], about: "the signed-on user (DUZ 4)" },
    { name: "userinfo", rpc: "ORWU USERINFO", inputs: [], about: "the signed-on user's CPRS settings (DUZ 4)" }
  ]
}.freeze
