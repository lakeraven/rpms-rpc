# frozen_string_literal: true

require "date"
require "rpms_rpc/api/referral"
require "rpms_rpc/api/ddr_fileman"

# The BMC SEARCH REFERRAL, BMC GET REFERRAL and BMC PRINT REFERRAL replies
# Referral.for_patient, .pending, .find and .print read, recorded as flows as
# PROFILE,MD on a fresh throwaway container (rpms-rpc#210, #621). A fresh
# container has no referral, so setup files three with DDR FILER: referral 1
# for demo patient 990001, filled in the way RCIS files a CHS referral
# (requesting provider, vendor, priority, purpose, scheduling notes, the
# documents to include, who called it in), and referrals 2 and 3 for demo
# patient 990002 with only the required fields. It files no RCIS DIAGNOSIS
# (#90001.01): with one on file, BMC GET REFERRAL faults on this build
# (https://github.com/lakeraven/openrpms/issues/1271). The letter is printed for
# referral 2: printing referral 1, a CHS referral filed without the rest of
# what RCIS files for one, faults in L^DIQ1 (NULSUBSC).
FILE = "90001"
REFERRAL = {} # the IENs setup files, for the flows

def file(file, values)
  rows = values.map { |field, value| { file: file, field: field, iens: "+1,", value: value } }
  filed = RpmsRpc::DdrFileman.filer(mode: "ADD", rows: rows)
  abort "setup: DDR FILER could not file #{file}: #{filed.inspect}" unless filed && filed[:success]
  filed[:iens].fetch(1)
end

SETUP = lambda do |session|
  RpmsRpc.configure { |cfg| cfg.client = session }
  REFERRAL[:full] = file(FILE, ".01" => "3261101", ".02" => "9000000000101", ".03" => "990001", ".04" => "C", ".06" => "206",
                               ".07" => "1", ".14" => "O", ".15" => "A", ".32" => "20", "1201" => "CARDIOLOGY CONSULT",
                               "1301" => "CALL PATIENT", "1302" => "14", "401" => "Y", "406" => "Y", "104" => "SMITH,CALLER")
  REFERRAL[:first] = file(FILE, ".01" => "3261101", ".02" => "9000000000102", ".03" => "990002", ".04" => "N", ".14" => "O", ".15" => "A")
  REFERRAL[:second] = file(FILE, ".01" => "3261102", ".02" => "9000000000103", ".03" => "990002", ".04" => "N", ".14" => "O", ".15" => "A")
  abort "setup: expected referrals 1-3 on a fresh container, filed #{REFERRAL.inspect}" unless REFERRAL.values == %w[1 2 3]
  RpmsRpc.reset!
  {}
end

CAPTURE = {
  rpc: "BMC SEARCH REFERRAL", entry_point: "SRCHREF^BMCRPC1",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair; DUZ 206)",
  access: "PMD123", verify: "PMD123!!",
  note: "Run on a fresh throwaway container. Setup files referral 1 (CHS, vendor 1 UNSPECIFIED, priority 20) for demo patient " \
        "990001 on 11/01/2026, and referrals 2 and 3 for demo patient 990002 on 11/01/2026 and 11/02/2026.",
  setup: SETUP,
  flows: {
    "search_full" => { about: "for_patient 990001: referral 1", run: -> { RpmsRpc::Referral.for_patient(990_001) } },
    "search_two" => { about: "for_patient 990002: referrals 2 and 3", run: -> { RpmsRpc::Referral.for_patient(990_002) } },
    "pending" => { about: "pending from 11/01/2026 to 11/30/2026: all three, open",
                   run: -> { RpmsRpc::Referral.pending(from: Date.new(2026, 11, 1), to: Date.new(2026, 11, 30)) } },
    "find_full" => { about: "find referral 1", run: -> { RpmsRpc::Referral.find("1") } },
    "print_plain" => { about: "print referral 2: the referral letter", run: -> { RpmsRpc::Referral.print("2") } },
    "print_not_found" => { about: "print of an IEN no referral has", run: -> { RpmsRpc::Referral.print("999") } }
  }
}.freeze
