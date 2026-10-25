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
    # callers that need to tell those apart must use {assessment}.
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
    # mixes a marker with other data (or repeats a marker) is corrupted or
    # concatenated: it is never verified absence. The result then carries
    # `conflict: true`; any real allergy rows in it are returned (they are
    # data, and must not be dropped because a marker rode along), and with
    # no rows it reads as not-assessed. Clean replies carry no :conflict key.
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

    # A marker next to other data (or twice): see {assessment}. Rows win over
    # the marker; with no rows the reply is not verified absence.
    def contradictory(mapping, lines)
      allergies = mapping.parse_many(lines)
      { assessed: !allergies.empty?, nka: false, allergies: allergies, conflict: true }
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
