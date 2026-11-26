# frozen_string_literal: true

require "rpms_rpc/api/terminology"

# The BSTS pick lists and ICD-9 maps RpmsRpc::Terminology reads under
# BSTSRPC, recorded as flows as the provider test role on the build's local
# BSTS cache: every subset, the problem list's subsets, an ICD-9 code the
# cache maps, one it maps to nothing, and the mapped code narrowed to a
# subset its concept is not in. Every flow reads. rpms-rpc#963.
CAPTURE = {
  rpc: "BSTS GET SUBSET LIST", entry_point: "SUBSET^BSTSRPC",
  signed_on_as: "PROFILE,MD (PMD123, the provider test role's published demo pair)",
  access: "PMD123", verify: "PMD123!!",
  note: "Run on a throwaway container; every call reads the local BSTS cache.",
  flows: {
    "subsets" => { about: "Terminology.subsets, every SNOMED CT subset the cache holds",
                   run: -> { RpmsRpc::Terminology.subsets } },
    "problem_list_subsets" => { about: "Terminology.subsets(problem_list: true), the SRCH subsets only",
                                run: -> { RpmsRpc::Terminology.subsets(problem_list: true) } },
    "from_icd9" => { about: "Terminology.from_icd9 of 250.00, which the cache maps to one concept",
                     run: -> { RpmsRpc::Terminology.from_icd9("250.00") } },
    "from_icd9_none" => { about: "Terminology.from_icd9 of 296.20, which the cache maps to none",
                          run: -> { RpmsRpc::Terminology.from_icd9("296.20") } },
    "from_icd9_in_subset" => { about: "Terminology.from_icd9 of 250.00 in SRCH Diabetes, which its concept is not in",
                               run: -> { RpmsRpc::Terminology.from_icd9("250.00", subsets: [ "SRCH Diabetes" ]) } }
  }
}.freeze
