# frozen_string_literal: true

require "date"
require "rpms_rpc/api/phr"
require "rpms_rpc/api/ddr_fileman"

# The PHR reads: BEHOCCD PHR (whether the patient uses their Personal Health
# Record), the immunization reconciliation count and the referrals on a visit
# (BEHOCCD GETREF), recorded as flows as the provider test role, PROFILE,MD.
# A fresh container has no PHR answer and no V REFERRAL, so setup files them
# with DDR FILER: DFN 2 said YES ten days ago; DFN 4 said YES twenty days ago
# and NO ten days ago; and an RCIS referral for DFN 4 recorded on its visit 2
# as a V REFERRAL. rpms-rpc#620, #221.
Phr = RpmsRpc::Phr
PHR_ACCESS = "9000001.8801"
REFERRAL_FILE = "90001"
V_REFERRAL = "9000010.59"
REFERRAL_NUMBER = "9000000000221"

def fileman(date) = format("%<y>03d%<m>02d%<d>02d", y: date.year - 1700, m: date.month, d: date.day)

def file!(what, rows, iens = {})
  filed = RpmsRpc::DdrFileman.filer(mode: "ADD", rows: rows, iens: iens)
  abort "setup: DDR FILER could not file #{what}: #{filed.inspect}" unless filed && filed[:success]
  filed[:iens].fetch(1)
end

# A PHR ACCESS DATE entry: its IEN is its date (DINUM), .02 is 1 YES or 0 NO.
def phr_answer(dfn, days_ago, access)
  date = fileman(Date.today - days_ago)
  file!("a PHR answer for DFN #{dfn}", [ { file: PHR_ACCESS, field: ".01", iens: "+1,#{dfn},", value: date },
                                         { file: PHR_ACCESS, field: ".02", iens: "+1,#{dfn},", value: access } ], { 1 => date })
end

CAPTURE = {
  rpc: "BEHOCCD PHR", entry_point: "PHR^BEHOCCD",
  signed_on_as: "PROFILE,MD (PMD123, the provider test role's published demo pair)",
  access: "PMD123", verify: "PMD123!!",
  note: "Run on a fresh throwaway container. Setup files PHR answers for DFN 2 (YES) and DFN 4 (YES, then NO), " \
        "and RCIS referral #{REFERRAL_NUMBER} for DFN 4 recorded on visit 2 as a V REFERRAL; every flow reads.",
  setup: lambda { |session|
    RpmsRpc.configure { |cfg| cfg.client = session }
    phr_answer(2, 10, "1")
    phr_answer(4, 20, "1")
    phr_answer(4, 10, "0")
    referral = file!("an RCIS referral", { ".01" => fileman(Date.today), ".02" => REFERRAL_NUMBER, ".03" => "4", ".04" => "N",
                                           ".14" => "O", ".15" => "A" }.map { |f, v| { file: REFERRAL_FILE, field: f, iens: "+1,", value: v } })
    file!("a V REFERRAL on visit 2", { ".01" => "3457005", ".02" => "4", ".03" => "2", ".06" => referral }
                                     .map { |f, v| { file: V_REFERRAL, field: f, iens: "+1,", value: v } })
    RpmsRpc.reset!
    {}
  },
  flows: {
    "enrollment_yes" => { about: "enrollment_status of DFN 2, who said YES", run: -> { Phr.enrollment_status(2) } },
    "enrollment_no" => { about: "enrollment_status of DFN 4, whose latest answer is NO", run: -> { Phr.enrollment_status(4) } },
    "enrollment_panel" => { about: "enrollment_status of DFN 990001, with no answer on file", run: -> { Phr.enrollment_status(990_001) } },
    "enrollment_unknown" => { about: "enrollment_status of DFN 999999999, not on file", run: -> { Phr.enrollment_status(999_999_999) } },
    "counts_unknown" => { about: "counts of DFN 999999999, not on file", run: -> { Phr.counts(999_999_999) } },
    "counts" => { about: "counts of DFN 2", run: -> { Phr.counts(2) } },
    "referrals" => { about: "referrals_for_visits of visits 1 and 2; visit 2 carries the V REFERRAL", run: -> { Phr.referrals_for_visits([ 1, 2 ]) } },
    "referrals_none" => { about: "referrals_for_visits of visit 1, which has none", run: -> { Phr.referrals_for_visits([ 1 ]) } }
  }
}.freeze
