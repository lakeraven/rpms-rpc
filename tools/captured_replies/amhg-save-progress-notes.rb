# frozen_string_literal: true

require "rpms_rpc/api/behavioral_health"
require "rpms_rpc/api/ddr_fileman"

# The conversations BehavioralHealth.save_progress_note has with the build,
# recorded as flows as PROVIDER,TEST on one BH visit setup files for synthetic
# patient DFN 990034: a save with a multi-line note, a comment, a placement
# disposition and referred-to; a save with an empty comment; and the refusals
# the build's replies lead to (the visit names another patient, a placement
# disposition that is inactive or not on file). rpms-rpc#622.
PN_BH = RpmsRpc::BehavioralHealth
PN_DDR = RpmsRpc::DdrFileman
PN_DFN = "990034"
PN_STATE = {}
PN_NOTE = "Line one.\nSecond.\n\nSYNTH #{'padding ' * 8}end\n".freeze

def pn_save(**overrides)
  PN_BH.save_progress_note(
    record_ien: PN_STATE[:rec], patient: PN_DFN, chief_complaint: "SYNTH CC", note: PN_NOTE,
    comment: "SYNTH comment line A\nSYNTH comment line B", placement_disposition: PN_STATE[:placement],
    referred_to: "SYN REF", **overrides
  )
end

# A refusal the gem raises after the build's replies; the flow keeps them.
def pn_refused
  yield
  raise "expected BehavioralHealth::SaveError"
rescue PN_BH::SaveError
  nil
end

CAPTURE = {
  rpc: "AMHG SAVE PROGRESS NOTES", entry_point: "PN^AMHGSVF",
  signed_on_as: "PROVIDER,TEST (PROV123, a published demo pair), the clinician that holds AMHGRPC",
  access: "PROV123", verify: "PROV123!!", context: "CIAV VUECENTRIC",
  setup: lambda { |client|
    RpmsRpc.configure { |cfg| cfg.client = client }
    first = ->(file) { PN_DDR.lister(file: file, fields: ".01", flags: "IP", max: "25")[:entries].first[:ien] }
    rec = PN_BH.save_visit(
      provider: client.duz.to_s, program: "MENTAL HEALTH", clinic: first.("40.7"),
      type_of_contact: first.("9002012.1"), encounter_date: Array(client.call_rpc("ORWU DT", "NOW")).first.to_s,
      encounter_location: first.("9999999.06"), community_of_service: first.("9999999.05"),
      appointment_with: "WALK-IN", patient: PN_DFN
    )
    placements = PN_DDR.lister(file: "9002013.6", fields: ".01;.02", flags: "IP", max: "50")[:entries]
    active = placements.find { |e| e[:pieces][1].to_s != "1" } or raise "no active placement disposition"
    inactive = placements.find { |e| e[:pieces][1].to_s == "1" }
    PN_STATE.merge!(rec: rec, placement: active[:ien], inactive: inactive&.dig(:ien))
    RpmsRpc.reset!
    { rec: rec }
  },
  note: "Run on a throwaway container. Setup files one BH visit for DFN 990034 (BehavioralHealth.save_visit, " \
        "as the live spec does) and lists the placement dispositions (9002013.6) for an active entry and an " \
        "inactive one (.02 = 1); the flows run in this order on that visit. Synthetic patient and text only.",
  calls: [
    { name: "save_record_not_on_file", context: "AMHGRPC",
      inputs: [ "E|999999|SYNTH CC|SYNTH note.||||#{PN_DFN}" ],
      about: "AMHG SAVE PROGRESS NOTES sent a record IEN no BH visit has (the gem refuses it first)" }
  ],
  flows: {
    "save" => { about: "save_progress_note: chief complaint, a multi-line note, a two-line comment, a placement, referred to",
                run: -> { pn_save } },
    "save_empty_comment" => { about: "save_progress_note with an empty comment: the comment is not read back",
                              run: -> { pn_save(note: "SYNTH note after blank comment.", comment: "") } },
    "other_patient" => { about: "save_progress_note naming DFN 990035 on DFN 990034's visit: refused after the pre-read",
                         run: -> { pn_refused { pn_save(patient: "990035") } } },
    "placement_not_on_file" => { about: "save_progress_note with a placement IEN no entry has: refused after its read",
                                 run: -> { pn_refused { pn_save(placement_disposition: "999999") } } },
    "placement_inactive" => { about: "save_progress_note with an inactive placement disposition: refused after its read",
                              run: -> { pn_refused { pn_save(placement_disposition: PN_STATE.fetch(:inactive) || raise("no inactive placement")) } } }
  }
}.freeze
