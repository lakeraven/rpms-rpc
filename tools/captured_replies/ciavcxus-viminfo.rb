# frozen_string_literal: true

# CIAVCXUS VIMINFO, as RpmsRpc::Session.bootstrap reads it. rpms-rpc#621.
CAPTURE = {
  rpc: "CIAVCXUS VIMINFO", entry_point: "VIMINFO^CIAVCXUS",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair)",
  access: "PMD123", verify: "PMD123!!",
  note: "DUZ 206 is PROFILE,MD on the build; nothing is filed.",
  calls: [
    { name: "profile_md", inputs: [ "206" ], about: "the signed-on user's own DUZ" },
    { name: "no_such_user", inputs: [ "9999" ], about: "a DUZ no user holds" }
  ]
}.freeze
