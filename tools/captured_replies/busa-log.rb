# frozen_string_literal: true

require "rpms_rpc/api/busa"

# RpmsRpc::Busa.log_security_audit on the build as PROVIDER,TEST
# (rpms-rpc#619). BUSARPC sits under BQIRPC and no published demo persona
# holds it (openrpms#1269), so before the run
# PROVIDER,TEST was given BUSARPC as a secondary menu option on the throwaway
# container through stock UPDATE^DIE. Each flow writes to the BUSA audit log.
CAPTURE = {
  rpc: "BUSA LOG SECURITY AUDIT ENTRY", entry_point: "RPC^BUSARPC",
  signed_on_as: "PROVIDER,TEST (PROV123, a published demo pair), given BUSARPC on the throwaway container",
  access: "PROV123", verify: "PROV123!!",
  note: "Run on a throwaway container. Before the run, PROVIDER,TEST was given the BUSARPC secondary menu " \
        "option through stock UPDATE^DIE; no published demo persona holds it.",
  calls: [],
  flows: {
    "logged" => { about: "a system event with no patient detail",
                  run: lambda {
                    RpmsRpc::Busa.log_security_audit(category: "S", action: "", call: "SYNTH RPC",
                                                     description: "Synthetic system event", detail: "")
                  } },
    "patient_detail" => { about: "a patient-related change event naming DFN 990031: the build files the " \
                                 "summary, then refuses the detail row, and answers 0^ with no message",
                          run: lambda {
                            RpmsRpc::Busa.log_security_audit(category: "P", action: "E", call: "SYNTH RPC",
                                                             description: "Synthetic demographic update",
                                                             detail: "990031")
                          } },
    "no_description" => { about: "a system event with no description",
                          run: lambda {
                            RpmsRpc::Busa.log_security_audit(category: "S", action: "", call: "SYNTH RPC",
                                                             description: "", detail: "")
                          } }
  }
}.freeze
