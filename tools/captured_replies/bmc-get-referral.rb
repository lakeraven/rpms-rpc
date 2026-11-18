# frozen_string_literal: true

require "date"
require "rpms_rpc/api/referral"
require "rpms_rpc/api/ddr_fileman"

# BMC GET REFERRAL, one RCIS REFERRAL (#90001) record, as Referral.find asks
# for it (GTRFBYID^BMCRPC1). Run on a fresh throwaway container: a fresh
# container has no referral, so setup files two minimal ones on demo patient
# 990001 with DDR FILER, the way test/live/referral_cancel_live_test.rb does:
# referral 1 with no REFERRAL # (.02), referral 2 with one. rpms-rpc#622, #767.
REFERRAL_FILE = "90001"
NUMBERED = "9000000000002"

def file_referral(number)
  d = Date.today
  values = { ".01" => format("%<y>03d%<m>02d%<d>02d", y: d.year - 1700, m: d.month, d: d.day),
             ".03" => "990001", ".04" => "N", ".14" => "O", ".15" => "A" }
  values[".02"] = number if number
  rows = values.map { |field, value| { file: REFERRAL_FILE, field: field, iens: "+1,", value: value } }
  filed = RpmsRpc::DdrFileman.filer(mode: "ADD", rows: rows)
  abort "setup: DDR FILER could not file a referral: #{filed.inspect}" unless filed && filed[:success]
  filed[:iens].fetch(1)
end

CAPTURE = {
  rpc: "BMC GET REFERRAL", entry_point: "GTRFBYID^BMCRPC1",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair)",
  access: "PMD123", verify: "PMD123!!",
  note: "Setup files referral 1 with no REFERRAL # (.02) and referral 2 with #{NUMBERED}. Called directly, " \
        "GTRFBYID dies on referral 1 (LIST^DIC on the C index finds nothing, CRTMSG^BMCRPC4 builds no line and " \
        "GTRFBYID+31 reads ^TMP($J,\"PRNRC\",1) undefined) and answers its message for an IEN not on file, which " \
        "the broker reads as a global name. The flows are what Referral.find sends for each case.",
  setup: lambda { |session|
    RpmsRpc.configure { |cfg| cfg.client = session }
    iens = [ file_referral(nil), file_referral(NUMBERED) ]
    abort "setup: expected referrals 1 and 2 on a fresh container, filed #{iens.inspect}" unless iens == %w[1 2]
    RpmsRpc.reset!
    {}
  },
  calls: [
    { name: "m_error", inputs: [ "1" ], expect_error: true, context: "BMCRPC",
      about: "referral 1, filed without a referral number: an M error inside GTRFBYID" },
    { name: "no_such_referral", inputs: [ "999999999" ], about: "an IEN no referral has: the routine's message, not a record" }
  ],
  flows: {
    "find_not_on_file" => { about: "Referral.find of an IEN no referral has", run: -> { RpmsRpc::Referral.find("999999999") } },
    "find_no_number" => { about: "Referral.find of referral 1, which has no referral number", run: -> { RpmsRpc::Referral.find("1") } },
    "find_numbered" => { about: "Referral.find of referral 2, filed with a referral number", run: -> { RpmsRpc::Referral.find("2") } }
  }
}.freeze
