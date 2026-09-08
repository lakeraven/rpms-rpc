# frozen_string_literal: true

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

    NOT_ASSESSED_SENTINEL = "^No Allergy Assessment" # ORQQAL.m:12
    NKA_SENTINEL          = "^No Known Allergies"    # ORQQAL.m:13

    # Allergy records only. An NKA or unassessed patient yields [] —
    # callers that need to tell those apart must use {assessment}.
    def for_patient(dfn)
      assessment(dfn)[:allergies]
    end

    # Three-state assessment result:
    #   { assessed: true,  nka: false, allergies: [...] } records on file
    #   { assessed: true,  nka: true,  allergies: [] }    assessed, NKA
    #   { assessed: false, nka: false, allergies: [] }    no assessment
    # An empty/indeterminate response (including the "^No allergies found."
    # fallback ORQQAL.m:15 emits when the classifier produced no rows) is
    # reported as not-assessed — the clinically safe reading, since claiming
    # "assessed" without evidence would suppress a real assessment prompt.
    def assessment(dfn)
      mapping = DataMapper[:allergy_list]
      response = RpmsRpc.client.call_rpc(mapping.rpc_name, dfn.to_s)
      lines = response_lines(response)

      return { assessed: false, nka: false, allergies: [] } if lines.include?(NOT_ASSESSED_SENTINEL)
      return { assessed: true, nka: true, allergies: [] } if lines.include?(NKA_SENTINEL)

      allergies = mapping.parse_many(lines)
      { assessed: !allergies.empty?, nka: false, allergies: allergies }
    end

    private

    def response_lines(response)
      case response
      when nil then []
      when String then response.split(/\r?\n/)
      else Array(response)
      end.map { |line| DataMapper.strip_recordset_separators(line.to_s) }
    end
  end
end
