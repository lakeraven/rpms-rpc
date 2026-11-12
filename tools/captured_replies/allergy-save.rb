# frozen_string_literal: true

require "rpms_rpc/api/allergy"

# The ORWDAL32 SAVE ALLERGY conversations RpmsRpc::Allergy.save and
# .no_known_allergies have with the build, recorded as flows as PROFILE,MD on
# demo patients with no allergy assessment (DFN 3 and 5). rpms-rpc#619.
#
# No flow holds the patient's allergy-edit lock: under the YDB CIA broker a
# busy lock answers 0 and files nothing (openrpms#1121), so a capture of it
# would record a false success.
Allergy = RpmsRpc::Allergy

ABALONE = {
  agent: "ABALONE", agent_pointer: "125;GMRD(120.82,", type: "F", nature: "A",
  originator: "206", originated_at: "3261109.12", observed_or_historical: "o",
  symptoms: [ { ien: "133", text: "RASH", date: "3261109" } ],
  comments: [ "Synthetic capture comment." ],
  reaction_date: "3261109", severity: "2"
}.freeze

CAPTURE = {
  rpc: "ORWDAL32 SAVE ALLERGY", entry_point: "EDITSAVE^ORWDAL32",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair; DUZ 206)",
  access: "PMD123", verify: "PMD123!!",
  note: "Run on a throwaway container: the flows file an allergy for DFN 3 and mark DFN 5 NKA, in this order. " \
        "Agent ABALONE (GMR ALLERGIES 125) and symptom RASH (SIGN/SYMPTOMS 133) are the build's own entries.",
  flows: {
    "save_new" => { about: "save: ABALONE, observed, on DFN 3, which has no allergy assessment",
                    run: -> { Allergy.save(3, ABALONE) } },
    "save_duplicate" => { about: "save: the same agent again on DFN 3",
                          run: -> { Allergy.save(3, ABALONE) } },
    "nka_with_allergies" => { about: "no_known_allergies on DFN 3, which now has an allergy",
                              run: -> { Allergy.no_known_allergies(3) } },
    "nka" => { about: "no_known_allergies on DFN 5, which has no allergy assessment",
               run: -> { Allergy.no_known_allergies(5) } },
    "nka_again" => { about: "no_known_allergies on DFN 5 again, once it reads NKA",
                     run: -> { Allergy.no_known_allergies(5) } },
    "assessment_after" => { about: "assessment of DFN 3 and DFN 5 after the writes",
                            run: -> { [ Allergy.assessment(3), Allergy.assessment(5) ] } }
  }
}.freeze
