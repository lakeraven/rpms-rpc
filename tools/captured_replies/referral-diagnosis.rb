# frozen_string_literal: true

require "date"
require "rpms_rpc/api/referral"
require "rpms_rpc/api/ddr_fileman"

# Referral.update with a diagnosis, then Referral.find, as the provider test
# role on bcer-9.0-20261124-60d39b6-ydb or later, the first release with
# openrpms#1271's fix (BMC GET REFERRAL no longer dies reading a diagnosis).
# Setup files referral 1 for demo patient 990001 with DDR FILER, as
# bmc-get-referral.rb does. rpms-rpc#915.
def file_referral
  d = Date.today
  values = { ".01" => format("%<y>03d%<m>02d%<d>02d", y: d.year - 1700, m: d.month, d: d.day), ".02" => "9000000000915",
             ".03" => "990001", ".04" => "N", ".14" => "O", ".15" => "A" }
  filed = RpmsRpc::DdrFileman.filer(mode: "ADD", rows: values.map { |f, v| { file: "90001", field: f, iens: "+1,", value: v } })
  abort "setup: DDR FILER could not file a referral: #{filed.inspect}" unless filed && filed[:success]
  filed[:iens].fetch(1)
end

CAPTURE = {
  rpc: "BMC UPDATE REFERRAL", entry_point: "UPDREFRL^BMCRPC2",
  signed_on_as: "PROFILE,MD (PMD123, the provider test role's published demo pair)",
  access: "PMD123", verify: "PMD123!!",
  note: "Run on a fresh throwaway container. Setup files referral 1 for DFN 990001.",
  setup: lambda { |session|
    RpmsRpc.configure { |cfg| cfg.client = session }
    abort "setup: expected referral 1 on a fresh container" unless file_referral == "1"
    RpmsRpc.reset!
    {}
  },
  flows: {
    "update" => { about: "Referral.update of referral 1 with diagnosis E11.9 and its narrative",
                  run: -> { RpmsRpc::Referral.update("1", diagnosis_code: "E11.9", diagnosis_narrative: "Type 2 diabetes mellitus") } },
    "find" => { about: "Referral.find of referral 1 after the update", run: -> { RpmsRpc::Referral.find("1") } },
    "unknown_code" => { about: "Referral.update of referral 1 with an ICD code not on file",
                        run: -> { RpmsRpc::Referral.update("1", diagnosis_code: "ZZZ.99", diagnosis_narrative: "No such code") } }
  }
}.freeze
