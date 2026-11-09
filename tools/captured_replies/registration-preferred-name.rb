# frozen_string_literal: true

require "rpms_rpc/api/ddr_fileman"

# The conversation RpmsRpc::Registration.preferred_name and
# set_preferred_name have with the build: AG's edit lock, a DDR GETS of
# #9000001 field 9001 and a DDR FILER EDIT of it, as PROFILE,REG (the lock under AGGRPC, the FileMan calls under CIAV VUECENTRIC, as the gem binds them)
# on seed patient HOTEL,DREW (DFN 990008). rpms-rpc#621.
DFN = "990008"

def gets_9001(dfn) = [ RpmsRpc::DdrFileman.gets_entry_param(file: "9000001", iens: "#{dfn},", fields: "9001", flags: "I") ]
def filer_9001(dfn, value) = [ "EDIT", { 1 => "9000001^9001^#{dfn},^#{value}" }, "", {} ]

CAPTURE = {
  rpc: "DDR GETS ENTRY DATA", entry_point: "GETSC^DDR2",
  signed_on_as: "PROFILE,REG (PREG123, a published demo pair)",
  access: "PREG123", verify: "PREG123!!",
  personas: {
    sched: { access: "PSCH123", verify: "PSCH123!!", signed_on_as: "PROFILE,SCHED (PSCH123, a published demo pair)" }
  },
  note: "Files and then clears the preferred name of DFN 990008 on a throwaway container; it ends blank, as it began.",
  calls: [
    { name: "lock", rpc: "AGG LOCK PATIENT", inputs: [ DFN ], global_array: true, context: "AGGRPC", about: "PROFILE,REG takes AG's edit lock" },
    { name: "lock_held", rpc: "AGG LOCK PATIENT", inputs: [ DFN ], global_array: true, as: :sched, context: "AGGRPC",
      about: "another user asks for the lock PROFILE,REG holds" },
    { name: "read_blank", context: "CIAV VUECENTRIC", inputs: gets_9001(DFN), about: "9001 before: no preferred name on file" },
    { name: "file_bobby", rpc: "DDR FILER", inputs: filer_9001(DFN, "Bobby"), about: "file the preferred name Bobby" },
    { name: "read_bobby", inputs: gets_9001(DFN), about: "9001 after: Bobby" },
    { name: "file_clear", rpc: "DDR FILER", inputs: filer_9001(DFN, "@"), about: "clear it: FileMan's @" },
    { name: "unlock", rpc: "AGG UNLOCK PATIENT", inputs: [ DFN ], global_array: true, context: "AGGRPC", about: "PROFILE,REG releases the lock" },
    { name: "read_no_such_patient", context: "CIAV VUECENTRIC", inputs: gets_9001("999999"), about: "9001 of a DFN no patient holds" },
    { name: "file_no_such_patient", rpc: "DDR FILER", inputs: filer_9001("999999", "Bobby"),
      about: "an EDIT FileMan refuses: the entry does not exist" }
  ]
}.freeze
