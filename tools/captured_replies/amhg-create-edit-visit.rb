# frozen_string_literal: true

require "rpms_rpc/api/behavioral_health"
require "rpms_rpc/api/ddr_fileman"

# The conversations BehavioralHealth.save_pcc_visit has with the build,
# recorded as flows as PROVIDER,TEST on one BH visit setup files for synthetic
# patient DFN 990033. On the pinned build the site's PCC link is off and
# save_visit files no activity type (.06), so EN^AMHBHRU answers
# "0~Activity Type Missing!" and links nothing: there is no linking reply to
# capture. The flows record that refusal, with and without a PCC visit named,
# and the refusals the gem reaches from the build's pre-reads (a PCC visit of
# another patient, a PCC visit or a BH record not on file). rpms-rpc#622.
PCC_BH = RpmsRpc::BehavioralHealth
PCC_DDR = RpmsRpc::DdrFileman
PCC_DFN = "990033"
PCC_STATE = {}

# A refusal the gem raises after the build's replies; the flow keeps them.
def pcc_refused
  yield
  raise "expected BehavioralHealth::SaveError"
rescue PCC_BH::SaveError
  nil
end

CAPTURE = {
  rpc: "AMHG CREATE/EDIT VISIT", entry_point: "PCC^AMHGPCC",
  signed_on_as: "PROVIDER,TEST (PROV123, a published demo pair), the clinician that holds AMHGRPC",
  access: "PROV123", verify: "PROV123!!", context: "CIAV VUECENTRIC",
  setup: lambda { |client|
    RpmsRpc.configure { |cfg| cfg.client = client }
    first = ->(file) { PCC_DDR.lister(file: file, fields: ".01", flags: "IP", max: "25")[:entries].first[:ien] }
    rec = PCC_BH.save_visit(
      provider: client.duz.to_s, program: "MENTAL HEALTH", clinic: first.("40.7"),
      type_of_contact: first.("9002012.1"), encounter_date: Array(client.call_rpc("ORWU DT", "NOW")).first.to_s,
      encounter_location: first.("9999999.06"), community_of_service: first.("9999999.05"),
      appointment_with: "WALK-IN", patient: PCC_DFN
    )
    visits = PCC_DDR.lister(file: "9000010", fields: ".05", flags: "IP", max: "200")[:entries]
    own = visits.find { |v| v[:pieces][0] == PCC_DFN } or raise "no PCC visit for DFN #{PCC_DFN}"
    other = visits.find { |v| v[:pieces][0] != PCC_DFN } or raise "no PCC visit of another patient"
    PCC_STATE.merge!(rec: rec, own: own[:ien], other: other[:ien])
    RpmsRpc.reset!
    { rec: rec }
  },
  note: "Run on a throwaway container. Setup files one BH visit for DFN 990033 (BehavioralHealth.save_visit, " \
        "as the live spec does) and finds a seeded PCC visit (#9000010) of that patient and one of another; " \
        "the flows run in this order on that visit. Synthetic patients only.",
  flows: {
    "activity_type_missing" => {
      about: "save_pcc_visit(record_ien:) on a visit with no activity type: the build links nothing",
      run: -> { pcc_refused { PCC_BH.save_pcc_visit(record_ien: PCC_STATE[:rec]) } }
    },
    "activity_type_missing_with_visit" => {
      about: "save_pcc_visit naming a PCC visit of the same patient: the build links nothing",
      run: -> { pcc_refused { PCC_BH.save_pcc_visit(record_ien: PCC_STATE[:rec], visit_ien: PCC_STATE[:own]) } }
    },
    "visit_of_another_patient" => {
      about: "save_pcc_visit naming a PCC visit of another patient: refused after the pre-reads",
      run: -> { pcc_refused { PCC_BH.save_pcc_visit(record_ien: PCC_STATE[:rec], visit_ien: PCC_STATE[:other]) } }
    },
    "visit_not_on_file" => {
      about: "save_pcc_visit naming a PCC visit IEN no entry has: refused after the pre-reads",
      run: -> { pcc_refused { PCC_BH.save_pcc_visit(record_ien: PCC_STATE[:rec], visit_ien: "999999") } }
    },
    "record_not_on_file" => {
      about: "save_pcc_visit on a BH record IEN no visit has: refused after the pre-read",
      run: -> { pcc_refused { PCC_BH.save_pcc_visit(record_ien: "999888777") } }
    }
  }
}.freeze
