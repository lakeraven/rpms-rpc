# frozen_string_literal: true

require_relative "../shape"

module RpmsRpc
  # Symbolic API for patient allergies (ORQQAL LIST). The RPC is
  # three-state (LIST^ORQQAL — ORQQAL.m:7): not-assessed
  # ("^No Allergy Assessment"), assessed with no known allergies
  # ("^No Known Allergies"), or assessed with allergy records. Use
  # {assessment} when the caller must distinguish NKA from unassessed
  # (FHIR AllergyIntolerance must); {for_patient} keeps the plain
  # record-array shape.
  module Allergy
    extend self
    extend Shape::Declarable

    NOT_ASSESSED_SENTINEL = "^No Allergy Assessment" # ORQQAL.m:12
    NKA_SENTINEL          = "^No Known Allergies"    # ORQQAL.m:13
    MARKERS               = [ NOT_ASSESSED_SENTINEL, NKA_SENTINEL ].freeze

    # Allergy records only. An NKA or unassessed patient yields [] —
    # callers that need to tell those apart must use {assessment}. The rows
    # of a conflicting reply (a marker beside other data) are returned too,
    # because hiding a possible allergy is unsafe; this method cannot tell a
    # verified list from a conflicting one, so a host that must make that
    # distinction MUST use {assessment} and read :assessed and :conflict.
    def for_patient(dfn)
      assessment(dfn)[:allergies]
    end
    shape :for_patient, resource: "allergies", verb: "GET", path: "/patients/{dfn}/allergies"

    # Three-state assessment result:
    #   { assessed: true,  nka: false, allergies: [...] } records on file
    #   { assessed: true,  nka: true,  allergies: [] }    assessed, NKA
    #   { assessed: false, nka: false, allergies: [] }    no assessment
    # An empty/indeterminate response (including the "^No allergies found."
    # fallback ORQQAL.m:15 emits when the classifier produced no rows) is
    # reported as not-assessed — the clinically safe reading, since claiming
    # "assessed" without evidence would suppress a real assessment prompt.
    #
    # A marker line counts only as the SOLE data line of the reply.
    # LIST^ORQQAL (ORQQAL.m:7-16) sets GMRARXN to "", 0 or 1 — mutually
    # exclusive branches — and writes the not-assessed / NKA marker to
    # ORAY(1) only in the two branches that write no allergy rows. A real
    # reply is therefore ONE marker line OR rows, never both. A reply that
    # mixes a marker with other data (or repeats a marker) is the signature
    # of a broker desync or a concatenated reply: its rows may belong to
    # another call (or patient), or the list may be truncated. It is never
    # vouched for:
    #   { assessed: false, nka: false, allergies: [...], conflict: true }
    # ALWAYS assessed: false, never nka. The parsed rows are still returned
    # — hiding a possible allergy is the other unsafe direction — but they
    # are never presented as an assessed, complete record. With no rows it is
    # the same shape with allergies: [], which keeps the method's fail-safe
    # (no evidence => not assessed). Clean replies carry no :conflict key.
    # Hosts that must tell a verified list from a conflicting one MUST use
    # {assessment} and read :assessed and :conflict; {for_patient} returns the
    # rows either way.
    def assessment(dfn)
      mapping = DataMapper[:allergy_list]
      response = RpmsRpc.client.call_rpc(mapping.rpc_name, dfn.to_s)
      lines = response_lines(response)
      data = lines.reject { |line| line.strip.empty? }
      markers = data.select { |line| MARKERS.include?(line) }

      return contradictory(mapping, lines) if !markers.empty? && data.size > 1
      return { assessed: false, nka: false, allergies: [] } if markers == [ NOT_ASSESSED_SENTINEL ]
      return { assessed: true, nka: true, allergies: [] } if markers == [ NKA_SENTINEL ]

      allergies = mapping.parse_many(lines)
      { assessed: !allergies.empty?, nka: false, allergies: allergies }
    end
    shape :assessment, resource: "allergies", verb: "GET", path: "/patients/{dfn}/allergies/assessment"

    private

    # A marker next to other data (or twice): see {assessment}. The rows stay
    # available, but the reply is never vouched for: assessed is always false
    # and nka is always false, whatever the rows are.
    def contradictory(mapping, lines)
      { assessed: false, nka: false, allergies: mapping.parse_many(lines), conflict: true }
    end

    def response_lines(response)
      case response
      when nil then []
      when String then response.split(/\r?\n/)
      else Array(response)
      end.map { |line| DataMapper.strip_recordset_separators(line.to_s) }
    end
  end
end
