# frozen_string_literal: true

# The eight pilot chart-read RPCs' error replies from an IRIS build
# (rpms-rpc#666): for a patient that does not exist, and for an input that
# raises an M error inside the routine. The IRIS release's own recordings hold
# only good-patient replies, so these come from a throwaway IRIS container
# stood up from the release's IRIS.DAT the way openrpms docs/CLIENTS.md says
# (bin/standup.sh on IRIS for Health Community, CIA on :9200).
#
# Each M-error input is the first that faulted, tried on this container:
# an empty DFN is a null subscript (<SUBSCRIPT>), 1E999 overflows (<MAXNUMBER>),
# and BEHOPTPC GETBDP, which quits early on any short bad DFN, faults only on a
# subscript longer than IRIS allows.
missing = "999999999"
too_long = "x" * 600
CAPTURE = {
  rpc: "ORWPT ID INFO", entry_point: "the eight chart reads of test/rpms_rpc/pilot_chart_reads_test.rb",
  signed_on_as: "MANAGER,SYSTEM (SYS123, the operator every image ships, a published pair)",
  access: "SYS123", verify: "RPMS.000",
  note: "Read-only. IRIS for Health Community 2026.2, release IRIS.DAT sha256 " \
        "36febbee9762af7daa1ae056758958038898b46722648eeb2031b4f2b52c86e4.",
  calls: [
    { name: "orwpt_id_info_missing_patient", rpc: "ORWPT ID INFO", inputs: [ missing ], about: "no such patient" },
    { name: "orwpt_id_info_m_error", rpc: "ORWPT ID INFO", inputs: [ "" ], expect_error: true,
      about: "an empty DFN: <SUBSCRIPT> at IDINFO+3^ORWPT" },
    { name: "behoptcx_ptinfo_missing_patient", rpc: "BEHOPTCX PTINFO", inputs: [ missing ], about: "no such patient" },
    { name: "behoptcx_ptinfo_m_error", rpc: "BEHOPTCX PTINFO", inputs: [ "1E999" ], expect_error: true,
      about: "DFN 1E999: <MAXNUMBER> at PTINFO+3^BEHOPTCX" },
    { name: "behoptpc_getbdp_missing_patient", rpc: "BEHOPTPC GETBDP", inputs: [ missing ], about: "no such patient" },
    { name: "behoptpc_getbdp_m_error", rpc: "BEHOPTPC GETBDP", inputs: [ too_long ], expect_error: true,
      about: "a 600-character DFN: <SUBSCRIPT> at ALLDP+15^BDPAPI" },
    { name: "orwpt_cwad_missing_patient", rpc: "ORWPT CWAD", inputs: [ missing ], about: "no such patient" },
    { name: "orwpt_cwad_m_error", rpc: "ORWPT CWAD", inputs: [ "1E999" ], expect_error: true,
      about: "DFN 1E999: <MAXNUMBER> at CWAD+9^ORQPT2" },
    { name: "orqqpl_list_missing_patient", rpc: "ORQQPL LIST", inputs: [ missing, "" ], about: "no such patient" },
    { name: "orqqpl_list_m_error", rpc: "ORQQPL LIST", inputs: [ "1E999", "" ], expect_error: true,
      about: "DFN 1E999: <MAXNUMBER> at LIST+25^GMPLUTL3" },
    { name: "orqqal_list_missing_patient", rpc: "ORQQAL LIST", inputs: [ missing ], about: "no such patient" },
    { name: "orqqal_list_m_error", rpc: "ORQQAL LIST", inputs: [ "1E999" ], expect_error: true,
      about: "DFN 1E999: <MAXNUMBER> at EN1+6^GMRAOR1" },
    { name: "orwps_active_missing_patient", rpc: "ORWPS ACTIVE", inputs: [ missing ], about: "no such patient" },
    { name: "orwps_active_m_error", rpc: "ORWPS ACTIVE", inputs: [ "" ], expect_error: true,
      about: "an empty DFN: <SUBSCRIPT> at OCL+3^PSOORRLO" },
    { name: "orqqvi_vitals_missing_patient", rpc: "ORQQVI VITALS", inputs: [ missing ], about: "no such patient" },
    { name: "orqqvi_vitals_m_error", rpc: "ORQQVI VITALS", inputs: [ "" ], expect_error: true,
      about: "an empty DFN: <SUBSCRIPT> at MSR+10^ORQQVI" }
  ]
}.freeze
