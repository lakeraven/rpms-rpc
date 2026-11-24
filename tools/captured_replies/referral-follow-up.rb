# frozen_string_literal: true

require "date"
require "rpms_rpc/api/referral"
require "rpms_rpc/api/ddr_fileman"

# Referral.record_follow_up, record_status and follow_up_state, as the
# provider test role, on a fresh container of bcer-9.0-20261124-60d39b6-ydb
# or later (its broker packs BMC UPDATE REFERRAL's 35 parameters for
# UPDREFRL(RSLT,P)). Setup files three referrals for demo patient 990001 with
# DDR FILER: 1 active, 2 active with ADDITIONAL INFO (.34) 1 and no INCLUDE
# flag Y, 3 cancelled (X) through Referral.cancel (filing C1 or X with DDR FILER
# fires BMCPXCHK, which dies without its caller's variables). rpms-rpc#722.
def file_referral(status, additional_info: nil)
  d = Date.today
  values = { ".01" => format("%<y>03d%<m>02d%<d>02d", y: d.year - 1700, m: d.month, d: d.day), ".03" => "990001",
             ".04" => "N", ".14" => "O", ".15" => status }
  values[".34"] = additional_info if additional_info
  filed = RpmsRpc::DdrFileman.filer(mode: "ADD", rows: values.map { |f, v| { file: "90001", field: f, iens: "+1,", value: v } })
  abort "setup: DDR FILER could not file a referral: #{filed.inspect}" unless filed && filed[:success]
  filed[:iens].fetch(1)
end

CAPTURE = {
  rpc: "BMC UPDATE REFERRAL", entry_point: "UPDREFRL^BMCRPC2",
  signed_on_as: "PROFILE,MD (PMD123, the provider test role's published demo pair)",
  access: "PMD123", verify: "PMD123!!",
  note: "Run on a fresh throwaway container. Setup files referrals 1 (A), 2 (A, .34 = 1) and 3 (cancelled, X) for DFN 990001.",
  setup: lambda { |session|
    RpmsRpc.configure { |cfg| cfg.client = session }
    filed = [ file_referral("A"), file_referral("A", additional_info: "1"), file_referral("A") ]
    abort "setup: could not cancel referral 3" unless RpmsRpc::Referral.cancel("3")[:success]
    abort "setup: expected referrals 1, 2 and 3 on a fresh container, filed #{filed.inspect}" unless filed == %w[1 2 3]
    RpmsRpc.reset!
    {}
  },
  flows: {
    "follow_up" => { about: "record_follow_up of referral 1: 12/4/2026 09:30 and a case note",
                     run: -> { RpmsRpc::Referral.record_follow_up("1", appointment_on: Date.new(2026, 12, 4), time: "09:30", case_note: "Seen by cardiology") } },
    "note_only" => { about: "record_follow_up of referral 1, a case note only: the date of service stays",
                     run: -> { RpmsRpc::Referral.record_follow_up("1", case_note: "Called the patient") } },
    "state" => { about: "follow_up_state of referral 1 after both", run: -> { RpmsRpc::Referral.follow_up_state("1") } },
    "additional_info" => { about: "record_follow_up of referral 2, whose .34 the INCLUDE flags would clear",
                           run: -> { RpmsRpc::Referral.record_follow_up("2", case_note: "Not filed") } },
    "closed" => { about: "record_follow_up of referral 3, which is cancelled (X)",
                  run: -> { RpmsRpc::Referral.record_follow_up("3", case_note: "Not filed") } },
    "not_on_file" => { about: "record_follow_up of an IEN no referral has",
                       run: -> { RpmsRpc::Referral.record_follow_up("999999", case_note: "Not filed") } },
    "status" => { about: "record_status of referral 1 to A1", run: -> { RpmsRpc::Referral.record_status("1", "A1") } },
    "status_back" => { about: "record_status of referral 1 back to A", run: -> { RpmsRpc::Referral.record_status("1", "A") } },
    "status_not_on_file" => { about: "record_status of an IEN no referral has",
                              run: -> { RpmsRpc::Referral.record_status("999999", "A1") } }
  }
}.freeze
