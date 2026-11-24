# frozen_string_literal: true

require_relative "../shape"
require_relative "../mappings"
require_relative "../reply"
require_relative "allergy"

module RpmsRpc
  # Find an allergen by name, for allergy entry: each match carries the
  # agent and the variable pointer that RpmsRpc::Allergy.save takes as
  # :agent and :agent_pointer, so a host never asks a user for a pointer.
  #
  # Underlying RPC: ORWDAL32 ALLERGY MATCH, ALLSRCH^ORWDAL32 as built. It
  # upper-cases the text and walks, in order, GMR ALLERGIES (#120.82) by
  # name and by synonym, the National Drug File generic (#50.6) and trade
  # (#50.67) names, drug ingredients (#50.416) and VA drug classes (#50.605),
  # keeping inactive and screened-out terms out. The local drug file (#50)
  # is announced but never searched on this build (IHS patch 1008).
  module Allergen
    extend self
    extend Shape::Declarable

    # The reply did not have the shape ALLSRCH^ORWDAL32 writes.
    class UnreadableReplyError < RpmsRpc::Error; end

    # ALLSRCH writes a header row for every source it walks, matches or not.
    HEADER_MARKER = "TOP"

    # The source a match came from (piece 5), as ALLSRCH numbers them:
    # FILENAME^ORWDAL32 text, with the synonym walk (2) reported as 1.
    SOURCES = {
      "1" => "VA Allergies File",
      "3" => "National Drug File - Generic Drug Name",
      "4" => "National Drug file - Trade Name",
      "5" => "Local Drug File",
      "7" => "Drug Ingredients File",
      "8" => "VA Drug Class File"
    }.freeze

    # ROOT is a global and one quoted cross-reference subscript, optionally
    # after a file number: GMRD(120.82,"D"), PSNDF(50.67,"T"), PSDRUG("B").
    ROOT = /\A\^?(?<global>[A-Z][A-Z0-9]*\()(?<file>\d+(?:\.\d+)?,)?"[^"]*"\)\z/

    # A #120.82 synonym match names the allergen and the synonym that
    # matched: "ASPIRIN RELATED MEDICATIONS <ASPIRIN>" (ORWDAL32.m:44).
    SYNONYM = /\A(?<name>.+?) <(?<synonym>[^<>]+)>\z/

    # Matches for +text+, in the order RPMS sends them:
    #   [ { agent:, agent_pointer:, synonym:, type:, source:, source_name: } ]
    # +agent+ and +agent_pointer+ go to Allergy.save unchanged. +synonym+ is
    # the synonym the text matched (#120.82 only, else nil). +type+ is the
    # allergy type RPMS holds for the agent (GMRATYPE letters; "D" for every
    # drug-file match). Trade names (#50.67) keep their trade-name pointer:
    # UPDATE^GMRAGUI1 files them as their generic (GMRAGUI1.m:103).
    #
    # Blank text is [] with no call. No match is []. A reply without
    # ALLSRCH's header rows (a refusal, an empty or a truncated reply) raises
    # UnreadableReplyError rather than reading as "no match". A row whose
    # text the client had to alter to make valid UTF-8 is left out: its name
    # would be filed changed.
    def search(text)
      return [] if blank?(text)

      mapping = DataMapper[:allergen_match]
      client = RpmsRpc.client
      response = mapping.in_context(client) { client.call_rpc(mapping.rpc_name, text.to_s) }
      lines, altered = Reply.lines_with_altered(response)
      # A whole-blob reply is split before its flag is read: a line holding
      # the replacement character is altered when the reply says it was.
      altered |= lines.each_index.select { |i| lines[i].to_s.include?(Reply::REPLACEMENT) } if Reply.altered?(response)
      rows = mapping.parse_many_flagged(lines.map(&:to_s), altered)
      raise UnreadableReplyError, "#{mapping.rpc_name} reply has no source headers" unless rows.any? { |row| header?(row) }

      rows.reject { |row| header?(row) || row[:altered] }.filter_map { |row| match(row) }
    end
    shape :search, resource: "allergens", verb: "GET", path: "/allergens"

    private

    def header?(row) = row[:type].to_s.empty? && row[:root].to_s.empty? && row[:source] == HEADER_MARKER

    def match(row)
      pointer = agent_pointer(row[:ien], row[:root])
      return unless pointer

      name, synonym = agent_and_synonym(row[:name].to_s)
      return if name.empty?

      source = row[:source].to_s
      {
        agent: name, agent_pointer: pointer, synonym: synonym,
        type: row[:type].to_s, source: source, source_name: SOURCES[source]
      }
    end

    # IEN;GLOBAL(FILE, from ROOT, the form Allergy.save checks. A row that
    # does not yield one is not offered.
    def agent_pointer(ien, root)
      parts = ROOT.match(root.to_s)
      return unless parts

      pointer = "#{ien};#{parts[:global]}#{parts[:file]}"
      pointer if pointer.match?(Allergy::AGENT_POINTER)
    end

    def agent_and_synonym(text)
      parts = SYNONYM.match(text)
      parts ? [ parts[:name].strip, parts[:synonym].strip ] : [ text.strip, nil ]
    end

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end
  end
end
