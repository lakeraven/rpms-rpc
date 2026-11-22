# frozen_string_literal: true

require "rpms_rpc/api/encounter"
require "rpms_rpc/api/ddr_fileman"

# The conversations RpmsRpc::Encounter.save has with the build: one BEHOENPC
# SAVE that files a visit, a V POV with its SNOMED concept, a V CPT, a V HEALTH
# FACTOR and the primary provider, with the read-backs before and after it
# (rpms-rpc#921). Recorded as flows as PROFILE,MD. Setup finds the clinic, the
# server's NOW and a health factor; the flows file onto synthetic DFN 990054.
# The second flow saves the same diagnosis again on the same visit: the build
# reuses the problem PROBLST^BEHOENP2 filed the first time. Run on a fresh
# throwaway container (the live spec uses DFN 990053, so the two do not meet).
Encounter = RpmsRpc::Encounter
DFN = 990_054
STATE = {} # what setup finds, for the flows

SETUP = lambda do |client|
  RpmsRpc.configure { |cfg| cfg.client = client }
  STATE[:clinic] = RpmsRpc::DdrFileman.lister(file: "44", fields: ".01", flags: "IP", from: "DEMO PRIMARY CAR",
                                              part: "DEMO PRIMARY CARE", max: "1")[:entries].first.fetch(:ien)
  STATE[:now] = Array(client.call_rpc("ORWU DT", "NOW")).first.to_s[0, 12]
  STATE[:factor] = RpmsRpc::DdrFileman.lister(file: "9999999.64", fields: ".01", flags: "IP", max: "1")[:entries]
                                       .first.fetch(:ien)
  STATE[:duz] = client.duz
  RpmsRpc.reset!
  {}
end

def encounter(diagnoses:, procedures: [], health_factors: [])
  Encounter.save(DFN, location_ien: STATE.fetch(:clinic), datetime: STATE.fetch(:now), service_category: "A",
                      provider_duz: STATE.fetch(:duz), diagnoses: diagnoses, procedures: procedures,
                      health_factors: health_factors)
end

DEPRESSION = { icd: "F32.9", snomed: "35489007", narrative: "SYNTH CAPTURE depressive disorder", primary: true }.freeze

CAPTURE = {
  rpc: "BEHOENPC SAVE", entry_point: "SAVE^BEHOENPC",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair; DUZ 206)",
  access: "PMD123", verify: "PMD123!!",
  note: "Run on a fresh throwaway container. Setup reads DEMO PRIMARY CARE, the server's NOW and the first HEALTH " \
        "FACTOR; the flows file onto synthetic DFN 990054. SNOMED 35489007 maps to F32.9 on the pinned build.",
  setup: SETUP,
  flows: {
    "save" => { about: "save: a visit with one diagnosis (F32.9, SNOMED 35489007), CPT A0021 and a health factor; " \
                       "PROBLST^BEHOENP2 files a problem for the concept and links the V POV to it",
                run: lambda {
                  encounter(diagnoses: [ DEPRESSION ], procedures: [ { cpt: "A0021" } ],
                            health_factors: [ { ien: STATE.fetch(:factor) } ])
                } },
    "save_again" => { about: "save: the same diagnosis again on the same visit; a new V POV, linked to the " \
                             "problem the first save filed",
                      run: -> { encounter(diagnoses: [ DEPRESSION ]) } }
  }
}.freeze
