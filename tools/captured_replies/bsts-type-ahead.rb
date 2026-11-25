# frozen_string_literal: true

# BSTS SEARCH TYPE AHEAD, the words VueCentric's problem picker offers as the
# user types, as Terminology.type_ahead asks for them: TAHEAD^BSTSRPC1
# (BSTSRPC1.m:129-250) on the build's local BSTS cache, under BSTSRPC. Reads
# only.
CAPTURE = {
  rpc: "BSTS SEARCH TYPE AHEAD", entry_point: "TAHEAD^BSTSRPC1",
  signed_on_as: "PROFILE,MD (PMD123, the provider test role's published demo pair)",
  access: "PMD123", verify: "PMD123!!", context: "BSTSRPC",
  note: "Run on a throwaway container; every call reads the local BSTS cache.",
  calls: [
    { name: "words", inputs: [ "36", "5", "diab", "" ],
      about: "SNOMED CT, five at most, the words that start with 'diab' in the IHS problem subsets" },
    { name: "no_words", inputs: [ "36", "10", "zzqxv", "" ],
      about: "a prefix no term holds: the header alone" }
  ]
}.freeze
