# frozen_string_literal: true

# BEHOSICX SITEINFO, the signed-on user's site, as RpmsRpc::Site.current
# reads it. rpms-rpc#621.
CAPTURE = {
  rpc: "BEHOSICX SITEINFO", entry_point: "SITEINFO^BEHOSICX",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair)",
  access: "PMD123", verify: "PMD123!!",
  note: "The build's demo site; nothing is filed.",
  calls: [
    { name: "current", inputs: [], about: "the site of the signed-on user" }
  ]
}.freeze
