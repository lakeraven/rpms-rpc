# frozen_string_literal: true

require "rpms_rpc/api/behavioral_health"
require "rpms_rpc/api/ddr_fileman"

# The conversations BehavioralHealth.save_pov has with the build, recorded as
# flows as PROVIDER,TEST on one BH visit setup files for synthetic patient
# DFN 990035: a full save, a replace-all save, and the refusals the build's
# replies lead to (the visit names another patient, a problem or Axis IV
# pointer not on file), plus AMHG's own reply to a problem it cannot file.
# rpms-rpc#622.
POV_BH = RpmsRpc::BehavioralHealth
POV_DDR = RpmsRpc::DdrFileman
POV_DFN = "990035"
POV_OTHER_DFN = "990036"
POV_NOT_ON_FILE = "999999"
POV_STATE = {}

def pov_listed(file, count)
  iens = POV_DDR.lister(file: file, fields: ".01", flags: "IP", max: "25")[:entries].map { |e| e[:ien] }
  raise "file #{file} lists fewer than #{count} entries" if iens.size < count

  iens.first(count)
end

def pov_save(**overrides)
  s = POV_STATE
  POV_BH.save_pov(
    record_ien: s[:rec], patient: POV_DFN,
    diagnoses: [ { problem: s[:problems][0], narrative: "SYNTH POV NARR A" },
                 { problem: s[:problems][1], narrative: "SYNTH POV NARR B" } ],
    axis_iii: "SYNTH AXIS III LINE", axis_iv: s[:stressors].first(2), axis_v: "55", gaf: "12", **overrides
  )
end

# A refusal the gem raises after the build's reply; the flow keeps the replies.
def pov_refused
  yield
  raise "expected BehavioralHealth::SaveError"
rescue POV_BH::SaveError
  nil
end

CAPTURE = {
  rpc: "AMHG SAVE POV", entry_point: "POV^AMHGSVF",
  signed_on_as: "PROVIDER,TEST (PROV123, a published demo pair), the clinician that holds AMHGRPC",
  access: "PROV123", verify: "PROV123!!", context: "CIAV VUECENTRIC",
  setup: lambda { |client|
    RpmsRpc.configure { |cfg| cfg.client = client }
    first = ->(file) { pov_listed(file, 1).first }
    rec = POV_BH.save_visit(
      provider: client.duz.to_s, program: "MENTAL HEALTH", clinic: first.("40.7"),
      type_of_contact: first.("9002012.1"), encounter_date: Array(client.call_rpc("ORWU DT", "NOW")).first.to_s,
      encounter_location: first.("9999999.06"), community_of_service: first.("9999999.05"),
      appointment_with: "WALK-IN", patient: POV_DFN, group_name: ""
    )
    POV_STATE.merge!(rec: rec, problems: pov_listed("9002012.2", 3), stressors: pov_listed("9002012.9", 3))
    RpmsRpc.reset!
    { rec: rec }
  },
  note: "Run on a throwaway container. Setup files one BH visit for DFN 990035 (BehavioralHealth.save_visit, " \
        "as the live spec does) and lists the first MHSS problems (9002012.2) and psychosocial stressors " \
        "(9002012.9); the flows run in this order on that visit. Synthetic patient and text only.",
  calls: [
    { name: "save_problem_not_on_file", context: "AMHGRPC",
      inputs: ->(s) { [ "E|#{s[:rec]}|#{POV_NOT_ON_FILE}~~SYNTH POV NARR A||||#{POV_DFN}|" ] },
      about: "AMHG SAVE POV sent a problem pointer no MHSS problem entry has (the gem refuses it first)" },
    { name: "save_record_not_on_file",
      inputs: [ "E|#{POV_NOT_ON_FILE}|1~~SYNTH POV NARR A||||#{POV_DFN}|" ],
      about: "AMHG SAVE POV sent a record IEN no BH visit has (the gem refuses it first)" }
  ],
  flows: {
    "save" => { about: "save_pov: two diagnoses, Axis III, two Axis IV stressors, Axis V 55, GAF 12",
                run: -> { pov_save } },
    "replace" => {
      about: "save_pov again: one other diagnosis, one other stressor, Axis V 70, GAF and Axis III cleared",
      run: lambda {
        s = POV_STATE
        POV_BH.save_pov(record_ien: s[:rec], patient: POV_DFN,
                        diagnoses: [ { problem: s[:problems][2], narrative: "SYNTH POV NARR C" } ],
                        axis_iv: [ s[:stressors][2] ], axis_v: "70", gaf: "", axis_iii: "")
      }
    },
    "other_patient" => { about: "save_pov naming DFN 990036 on DFN 990035's visit: refused after the pre-read",
                         run: -> { pov_refused { pov_save(patient: POV_OTHER_DFN) } } },
    "problem_not_on_file" => {
      about: "save_pov with a problem pointer no MHSS problem entry has: refused after the pointer read",
      run: -> { pov_refused { pov_save(diagnoses: [ { problem: POV_NOT_ON_FILE, narrative: "SYNTH POV NARR A" } ]) } }
    },
    "axis_iv_not_on_file" => {
      about: "save_pov with an Axis IV pointer no psychosocial stressor entry has: refused after the pointer read",
      run: -> { pov_refused { pov_save(axis_iv: [ POV_NOT_ON_FILE ]) } }
    }
  }
}.freeze
