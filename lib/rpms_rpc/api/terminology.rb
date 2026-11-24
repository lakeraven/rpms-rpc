# frozen_string_literal: true

require_relative "../shape"
require_relative "../mappings"

module RpmsRpc
  # IHS Standard Terminology (BSTS) through its own broker option, BSTSRPC
  # (rpms-rpc#916): SNOMED CT concept search, one concept's detail, and the
  # code sets BSTS serves. Each reads the local BSTS cache: the search asks
  # for a local listing, so no call reaches out to a terminology server.
  #
  # A user whose menu lacks BSTSRPC is refused the bind, and the refusal
  # raises (Client::ContextBindRefusedError), never an empty list.
  module Terminology
    extend self
    extend Shape::Declarable

    CONTEXT = "BSTSRPC"

    # SNOMED CT US Edition, BSTS's default namespace (TAHEAD^BSTSRPC1,
    # SEARCH^BSTSAPIA: P3).
    SNOMED_CT = 36

    # SNOMED CT concepts whose terms match +text+, as SEARCH^BSTSRPC answers
    # them (BSTSRPC.m:6-131, the row at :128-129):
    #
    #   search("diabetes mellitus", code_set: 36, max: 25)
    #   => [{ concept_id: "73211009", dts_id: "73211", description_id: "121589010",
    #         term: "Diabetes mellitus", preferred_term:, fsn: "Diabetes mellitus (disorder)",
    #         icd: ["E11.9"] }, ...]
    #
    # term is the matched description, preferred_term the concept's
    # preferred one. dts_id is the BSTS concept IEN that concept takes. icd
    # is the row's mapped ICD codes; the routine joins them with $C(28),
    # which the CIA line delivers as a space (README, Reply encoding), and an
    # ICD code has no space, so it splits there. The row's subset and
    # synonym lists are joined the same way but their entries hold spaces,
    # so they are not returned. +subsets+
    # limits the search to those BSTS subsets ("~"-joined by the routine);
    # nil searches BSTS's default, the IHS Problem List (SEARCH^BSTSAPIA,
    # P4). Text with "|" or "^" is refused before the wire: SEARCH^BSTSRPC
    # reads "|" as its piece separator.
    def search(text, code_set: SNOMED_CT, max: 25, subsets: nil)
      text = text.to_s.strip
      raise ArgumentError, "search text is empty" if text.empty?
      raise ArgumentError, "search text must not contain | or ^: #{text.inspect}" if text.match?(/[|^]/)

      subset = Array(subsets).join("~")
      raise ArgumentError, "a subset must not contain | or ^" if subset.match?(/[|^]/)

      # SEARCH^BSTSAPIA pieces: text | S (synonyms) | namespace | subsets |
      # date | max | return info | no dates | batch start | batch size | LOCAL.
      param = [ text, "S", Integer(code_set), subset, "", Integer(max), "", "", "", "", "1" ].join("|")
      DataMapper.bsts_search.fetch_many(param).map { |row| split_icd(row) }
    end
    shape :search, resource: "terminologies", verb: "GET", path: "/terminologies"

    # One concept's detail by its BSTS concept IEN (+dts_id+ from search),
    # as DETAIL^BSTSRPC1 answers it (BSTSRPC1.m:59-128):
    #
    #   concept("73211")
    #   => { concept_id: "73211009", dts_id: "73211", fsn:, preferred_term:, term:,
    #        icd: ["E11.9"], prompt_laterality: false, default_status:, requires_episodicity: false,
    #        prompt_abnormal_finding: false, selectable: true }
    #
    # nil when no concept has that IEN (the routine answers its header and
    # no row).
    def concept(dts_id)
      raise ArgumentError, "dts_id must be a positive integer: #{dts_id.inspect}" unless dts_id.to_s.match?(/\A[1-9]\d*\z/)

      row = DataMapper.bsts_concept_detail.fetch_many(dts_id.to_s).first
      row && split_icd(row).merge(selectable: row[:selectable] == "Y")
    end
    shape :concept, resource: "terminologies", verb: "GET", path: "/terminologies/concept"

    # The code sets the local BSTS cache serves, CDSET^BSTSRPC with LOCAL
    # (BSTSRPC.m:372-437): [{ id: 36, name: "SNOMED CT US Edition" }, ...].
    def code_sets
      DataMapper.bsts_code_sets.fetch_many("1").map { |row| row.merge(id: row[:id].to_i) }
    end
    shape :code_sets, resource: "terminologies", verb: "GET", path: "/terminologies/code-sets"

    private

    # The ICD codes of a row, $C(28)-joined by the routine: a space or the
    # byte itself, whichever the line carried.
    def split_icd(row)
      row.merge(icd: row[:icd].to_s.split(/[\x1C\s]+/).reject(&:empty?))
    end
  end
end
