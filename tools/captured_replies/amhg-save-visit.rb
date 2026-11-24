# frozen_string_literal: true

require "rpms_rpc/api/behavioral_health"
require "rpms_rpc/api/ddr_fileman"

# The conversations BehavioralHealth.save_visit has with the build, recorded
# as flows as PROVIDER,TEST for synthetic patient DFN 990036: an add with
# every field and a group, an add with the required fields only, an edit of
# the first visit with a group and one with no group change, and the
# refusals the build's replies lead to (a clinic or a patient not on file, an
# edit naming another patient, a provider who is not the visit's primary, a
# record not on file), plus AMHG's own reply to an edit of a record no visit
# has. rpms-rpc#622.
SV_BH = RpmsRpc::BehavioralHealth
SV_DDR = RpmsRpc::DdrFileman
SV_DFN = "990036"
SV_OTHER_DFN = "990037"
SV_NOT_ON_FILE = "999999"
SV_STATE = {}

def sv_fields(**overrides)
  s = SV_STATE
  { provider: s[:provider], program: "MENTAL HEALTH", clinic: s[:clinic], type_of_contact: s[:type],
    encounter_date: s[:now], encounter_location: s[:location], community_of_service: s[:community],
    appointment_with: "APPOINTMENT", patient: SV_DFN, group_name: "SYNTH GROUP ALPHA", group_time: "45",
    activity_time: "30" }.merge(overrides)
end

def sv_required
  sv_fields.slice(:provider, :program, :clinic, :type_of_contact, :encounter_location, :community_of_service,
                  :patient).merge(encounter_date: SV_STATE[:now].split(".").first)
end

# A refusal the gem raises after the build's replies; the flow keeps them.
def sv_refused
  yield
  raise "expected BehavioralHealth::SaveError"
rescue SV_BH::SaveError
  nil
end

CAPTURE = {
  rpc: "AMHG SAVE VISIT", entry_point: "VISIT^AMHGSVF",
  signed_on_as: "PROVIDER,TEST (PROV123, a published demo pair), the clinician that holds AMHGRPC",
  access: "PROV123", verify: "PROV123!!", context: "CIAV VUECENTRIC",
  setup: lambda { |client|
    RpmsRpc.configure { |cfg| cfg.client = client }
    first = ->(file) { SV_DDR.lister(file: file, fields: ".01", flags: "IP", max: "25")[:entries].first[:ien] }
    users = SV_DDR.lister(file: "200", fields: ".01", flags: "IP", max: "25")[:entries].map { |e| e[:ien] }
    SV_STATE.merge!(
      provider: client.duz.to_s, other_provider: (users - [ client.duz.to_s ]).first,
      clinic: first.("40.7"), type: first.("9002012.1"), location: first.("9999999.06"),
      community: first.("9999999.05"),
      # A FileMan date and time to the minute, as a clinician enters it.
      now: Array(client.call_rpc("ORWU DT", "NOW")).first.to_s[/\A\d{7}(\.\d{1,4})?/]
    )
    RpmsRpc.reset!
    SV_STATE.dup
  },
  note: "Run on a throwaway container. Setup lists the first clinic, type of contact, location and community " \
        "and another user (#200), and reads the server's now (ORWU DT); the flows run in this order for " \
        "DFN 990036, the edits on the visit the first add filed. Synthetic patient and text only.",
  calls: [
    { name: "save_record_not_on_file", context: "AMHGRPC",
      inputs: lambda { |s|
        [ "E|#{SV_NOT_ON_FILE}|#{s[:provider]}|MENTAL HEALTH|#{s[:clinic]}|#{s[:type]}||#{s[:now]}|" \
          "#{s[:location]}|APPOINTMENT|#{s[:community]}|#{SV_DFN}||||" ]
      },
      about: "AMHG SAVE VISIT sent an edit of a record IEN no BH visit has (the gem refuses it first)" }
  ],
  flows: {
    "add" => { about: "save_visit add: every field, a group of 45 minutes, activity time 30",
               run: -> { SV_STATE[:rec] = SV_BH.save_visit(**sv_fields) } },
    "add_required" => { about: "save_visit add: the required fields only, the encounter date without a time",
                        run: -> { SV_BH.save_visit(**sv_required) } },
    "edit" => { about: "save_visit edit of the first visit: every field, the group unchanged",
                run: -> { SV_BH.save_visit(**sv_fields(record_ien: SV_STATE[:rec])) } },
    "edit_no_group_change" => {
      about: "save_visit edit with a blank group name: the group fields are not sent or read back",
      run: -> { SV_BH.save_visit(**sv_fields(record_ien: SV_STATE[:rec], group_name: "", group_time: nil, activity_time: nil)) }
    },
    "add_clinic_not_on_file" => { about: "save_visit add with a clinic IEN no entry has: refused after its read",
                                  run: -> { sv_refused { SV_BH.save_visit(**sv_fields(clinic: SV_NOT_ON_FILE)) } } },
    "add_patient_not_on_file" => { about: "save_visit add for a DFN no patient has: refused after its read",
                                   run: -> { sv_refused { SV_BH.save_visit(**sv_fields(patient: SV_NOT_ON_FILE)) } } },
    "edit_other_patient" => {
      about: "save_visit edit naming DFN 990037 on DFN 990036's visit: refused after the pre-read",
      run: -> { sv_refused { SV_BH.save_visit(**sv_fields(record_ien: SV_STATE[:rec], patient: SV_OTHER_DFN)) } }
    },
    "edit_not_primary" => {
      about: "save_visit edit naming a provider who is not the visit's primary: refused after the provider list",
      run: lambda {
        sv_refused { SV_BH.save_visit(**sv_fields(record_ien: SV_STATE[:rec], provider: SV_STATE[:other_provider])) }
      }
    },
    "edit_record_not_on_file" => {
      about: "save_visit edit of a record IEN no visit has: refused after the pre-read",
      run: -> { sv_refused { SV_BH.save_visit(**sv_fields(record_ien: SV_NOT_ON_FILE)) } }
    }
  }
}.freeze
