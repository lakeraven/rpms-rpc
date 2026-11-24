# frozen_string_literal: true

require "rpms_rpc/api/terminology"

# The IHS Standard Terminology reads RpmsRpc::Terminology makes under
# BSTSRPC, recorded as flows as the provider test role on the build's local
# BSTS cache: a SNOMED CT search with a concept mapped to two ICD codes, one
# concept's detail, an IEN no concept has, a search that matches nothing,
# and the code sets. Every flow reads. rpms-rpc#916.
CAPTURE = {
  rpc: "BSTS SNOMED SEARCH", entry_point: "SEARCH^BSTSRPC",
  signed_on_as: "PROFILE,MD (PMD123, the provider test role's published demo pair)",
  access: "PMD123", verify: "PMD123!!",
  note: "Run on a throwaway container; every call reads the local BSTS cache.",
  flows: {
    "search" => { about: "Terminology.search of 'diabetes', 25 at most",
                  run: -> { RpmsRpc::Terminology.search("diabetes", max: 25) } },
    "search_none" => { about: "Terminology.search of a string no term holds",
                       run: -> { RpmsRpc::Terminology.search("zzzqqq") } },
    "concept" => { about: "Terminology.concept of 1119000077, Diabetes type 2 with kidney disease",
                   run: -> { RpmsRpc::Terminology.concept("1119000077") } },
    "concept_unknown" => { about: "Terminology.concept of an IEN no concept has",
                           run: -> { RpmsRpc::Terminology.concept("999999999") } },
    "code_sets" => { about: "Terminology.code_sets, the local listing", run: -> { RpmsRpc::Terminology.code_sets } }
  }
}.freeze
