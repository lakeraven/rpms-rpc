# frozen_string_literal: true

require_relative "../shape"
require_relative "../mappings"

module RpmsRpc
  # IHS Standard Terminology (BSTS) through its own broker option, BSTSRPC
  # (rpms-rpc#916, #963): SNOMED CT concept search, the type-ahead words
  # before a search, one concept's detail, the code sets and subsets BSTS
  # serves, ICD-9 to SNOMED CT maps, and the signed-on user's search
  # preferences. Each read asks the local BSTS cache, so no call relies on a
  # terminology server.
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

    # The words the local BSTS cache's terms hold that start with +prefix+,
    # as TAHEAD^BSTSRPC1 answers them (BSTSRPC1.m:129-250): the picker
    # VueCentric's problem entry offers as the user types, before a search.
    #
    #   type_ahead("diab", max: 3) => ["Diabetes", "Diabetes-deafness", "Diabetes-nephrosis"]
    #
    # [] when no term holds such a word. SNOMED CT searches the IHS problem
    # subsets unless +subsets+ names others (:157). A blank prefix is
    # refused before the wire: the routine answers it with no rows and an
    # error (:153), which would read as "no such word".
    def type_ahead(prefix, max: 10, code_set: SNOMED_CT, subsets: nil)
      prefix = prefix.to_s.strip
      raise ArgumentError, "type-ahead text is empty" if prefix.empty?
      raise ArgumentError, "type-ahead text must not contain ^: #{prefix.inspect}" if prefix.include?("^")

      subset = Array(subsets).join("~")
      raise ArgumentError, "a subset must not contain ^" if subset.include?("^")

      DataMapper.bsts_type_ahead.fetch_many(Integer(code_set).to_s, Integer(max).to_s, prefix, subset)
                .map { |row| row[:word].to_s.strip }.reject(&:empty?)
    end
    shape :type_ahead, resource: "terminologies", verb: "GET", path: "/terminologies/type-ahead"

    # The code sets the local BSTS cache serves, CDSET^BSTSRPC with LOCAL
    # (BSTSRPC.m:372-437): [{ id: 36, name: "SNOMED CT US Edition" }, ...].
    def code_sets
      DataMapper.bsts_code_sets.fetch_many("1").map { |row| row.merge(id: row[:id].to_i) }
    end
    shape :code_sets, resource: "terminologies", verb: "GET", path: "/terminologies/code-sets"

    # The subsets the local BSTS cache holds for +code_set+, as
    # SUBSET^BSTSRPC answers them (BSTSRPC.m:320-370), the pick lists
    # VueCentric's picker offers:
    #
    #   subsets => [{ name: "SRCH Behavioral Health", display_name: "Behavioral Health" }, ...]
    #
    # display_name drops the "SRCH " a problem-list subset opens with. A
    # name is what search(subsets:) and from_icd9(subsets:) take.
    # +problem_list+ keeps only the SRCH subsets, the problem list's.
    def subsets(code_set: SNOMED_CT, problem_list: false)
      param = [ Integer(code_set), "1", "", problem_list ? "1" : "" ].join("|")
      mapping = DataMapper.bsts_subsets
      mapping.parse_many(recordset_rows(mapping, param))
    end
    shape :subsets, resource: "terminologies", verb: "GET", path: "/terminologies/subsets"

    ICD9_CODE = /\A(?:\d{3}|V\d{2}|E\d{3})(?:\.\d{1,2})?\z/i

    # The SNOMED CT concepts the local BSTS cache maps an ICD-9-CM +code+
    # to, as ICD2SMD^BSTSRPC answers them (BSTSRPC.m:136-304):
    #
    #   from_icd9("250.00")
    #   => [{ concept_id: "309597007", description_id: "453054011",
    #         preferred_term: "Foot abnormality - diabetes-related", icd: ["250.00"] }]
    #
    # [] when the cache maps the code to none. +subsets+ keeps only the
    # concepts in those BSTS subsets. The routine also answers each
    # concept's parents, children and subsets, joined with separators the
    # CIA line delivers as spaces; they are not returned (concept and
    # search give a concept's detail). A code that is not ICD-9-CM shaped
    # is refused before the wire: the routine reads one that starts with
    # "?" as a text search.
    def from_icd9(code, subsets: nil)
      code = code.to_s.strip
      raise ArgumentError, "not an ICD-9-CM code: #{code.inspect}" unless code.match?(ICD9_CODE)

      subset = Array(subsets).join("~")
      raise ArgumentError, "a subset must not contain | or ^" if subset.match?(/[|^]/)

      param = subset.empty? ? code : "#{code}|#{subset}"
      mapping = DataMapper.bsts_icd9_to_snomed
      mapping.parse_many(recordset_rows(mapping, param)).map { |row| split_icd(row) }
    end
    shape :from_icd9, resource: "terminologies", verb: "GET", path: "/terminologies/from-icd9"

    # BSTS answered a terminology write with its own refusal: +package_message+
    # is its text ("Invalid Record Count Value"). Never a silent success.
    class BstsError < RpmsRpc::Client::RpcError
      attr_reader :package_message

      def initialize(rpc, package_message)
        @package_message = package_message
        super("#{rpc}: #{package_message}")
      end
    end

    SEARCH_TYPES = { "F" => :fsn, "S" => :synonym }.freeze

    # The signed-on user's SNOMED CT search preferences, as GET^BSTSUPRF
    # answers them (BSTSUPRF.m:90-136):
    #
    #   preferences
    #   => { search_type: :synonym, max: 100, parents_children: true, autocomplete_disabled: false }
    #
    # search_type is :fsn (fully specified name) or :synonym; max is the
    # records a search returns, 25, 50, 100, 200 or :all. nil when the user
    # has saved none: BSTS's defaults apply (:fsn, 50, false, false).
    def preferences
      mapping = DataMapper.bsts_user_prefs
      rows = recordset_rows(mapping, SNOMED_CT.to_s)
      raise Client::RpcError, "#{mapping.rpc_name} answered #{rows.size} settings rows" unless rows.size == 1

      fs, cnt, pc, ac = rows.first.split("|", -1)
      return nil if [ fs, cnt, pc, ac ].all? { |v| v.to_s.empty? }

      { search_type: SEARCH_TYPES.fetch(fs) { raise Client::RpcError, "#{mapping.rpc_name}: unknown search type #{fs.inspect}" },
        max: cnt == "ALL" ? :all : Integer(cnt, 10), parents_children: pc == "1", autocomplete_disabled: ac == "1" }
    end
    shape :preferences, resource: "terminologies", verb: "GET", path: "/terminologies/preferences"

    # File the signed-on user's SNOMED CT search preferences, as
    # SET^BSTSUPRF does (BSTSUPRF.m:6-88): every field is filed, so one left
    # out takes BSTS's default. true when filed; BstsError with BSTS's text
    # when it refuses a value (max: 75 is "Invalid Record Count Value").
    # BSTS files these under SNOMED CT only: the routine discards the code
    # set it is sent (:24).
    def update_preferences(search_type: :fsn, max: 50, parents_children: false, autocomplete_disabled: false)
      fs = SEARCH_TYPES.key(search_type) or raise ArgumentError, "search_type is :fsn or :synonym: #{search_type.inspect}"
      cnt = max == :all ? "ALL" : Integer(max).to_s
      set_preferences([ fs, cnt, flag(parents_children), flag(autocomplete_disabled) ].join("|"))
    end
    shape :update_preferences, resource: "terminologies", verb: "PUT", path: "/terminologies/preferences"

    # Delete the signed-on user's SNOMED CT search preferences, so BSTS's
    # defaults apply again: SET^BSTSUPRF with every field blank (RESET,
    # BSTSUPRF.m:138-171). true when done.
    def delete_preferences
      set_preferences("")
    end
    shape :delete_preferences, resource: "terminologies", verb: "DELETE", path: "/terminologies/preferences"

    # Tell BSTS the user picked a concept, as VueCentric does after a
    # selection: SELECT^BSTSRPC1 (BSTSRPC1.m:9-57), with the term's
    # description id and the subset it was picked from when known. true when
    # BSTS answers success. BSTS*2.0*7 switched concept-selection logging off
    # (CENABLE^BSTSAPIL quits 0), so on these builds BSTS answers success and
    # queues nothing. A blank concept id is refused before the wire: the
    # routine answers it with nothing at all.
    def record_selection(concept_id, description_id: nil, subset: nil, code_set: SNOMED_CT)
      raise ArgumentError, "concept_id must be a SNOMED CT id: #{concept_id.inspect}" unless concept_id.to_s.match?(/\A\d+\z/)
      raise ArgumentError, "description_id must be a SNOMED CT id: #{description_id.inspect}" unless description_id.nil? || description_id.to_s.match?(/\A\d+\z/)
      raise ArgumentError, "a subset must not contain | or ^" if subset.to_s.match?(/[|^]/)

      mapping = DataMapper.bsts_log_selected
      rows = recordset_rows(mapping, concept_id.to_s, Integer(code_set).to_s, description_id.to_s, subset.to_s)
      return true if rows == [ "1" ]

      raise Client::RpcError, "#{mapping.rpc_name} answered #{rows.inspect}, not success"
    end
    shape :record_selection, resource: "terminologies", verb: "POST", path: "/terminologies/selection"

    private

    # The ICD codes of a row, $C(28)-joined by the routine: a space or the
    # byte itself, whichever the line carried.
    def split_icd(row)
      row.merge(icd: row[:icd].to_s.split(/[\x1C\s]+/).reject(&:empty?))
    end

    # SET^BSTSUPRF: "1^" filed, "-1^<text>" refused, which raises with
    # BSTS's text.
    def set_preferences(input)
      mapping = DataMapper.bsts_set_user_prefs
      rows = recordset_rows(mapping, SNOMED_CT.to_s, input)
      result, message = rows.first.split("^", 2) if rows.size == 1
      return true if result == "1"
      raise BstsError.new(mapping.rpc_name, message.to_s) if result.to_s.start_with?("-")

      raise Client::RpcError, "#{mapping.rpc_name} answered #{rows.inspect}, not a result"
    end

    def flag(value) = value ? "1" : "0"

    # The data rows of a BMX typed reply, the header dropped. A reply with no
    # header is not an empty answer: the routine set BMXSEC or failed, so it
    # raises.
    def recordset_rows(mapping, *params)
      client = RpmsRpc.client
      reply = mapping.in_context(client) { client.call_rpc(mapping.rpc_name, *params) }
      lines = reply.is_a?(String) ? reply.split(/\r\n|\r|\n/) : Array(reply)
      lines = lines.map { |line| DataMapper.strip_recordset_separators(line.to_s) }.reject(&:empty?)
      raise Client::RpcError, "#{mapping.rpc_name} answered no recordset header" unless lines.first && DataMapper.recordset_header_row?(lines.first)

      lines.drop(1)
    end
  end
end
