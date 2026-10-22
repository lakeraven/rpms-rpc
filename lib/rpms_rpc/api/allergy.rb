# frozen_string_literal: true

module RpmsRpc
  # Symbolic API for patient allergies. The read is ORQQAL LIST,
  # three-state (LIST^ORQQAL — ORQQAL.m:7): not-assessed
  # ("^No Allergy Assessment"), assessed with no known allergies
  # ("^No Known Allergies"), or assessed with allergy records. Use
  # {assessment} when the caller must distinguish NKA from unassessed
  # (FHIR AllergyIntolerance must); {for_patient} keeps the plain
  # record-array shape.
  #
  # The write is ORWDAL32 SAVE ALLERGY, EDITSAVE^ORWDAL32
  # (ORWDAL32.m:119): ORALIEN "" adds, ORDFN is the patient, and
  # OREDITED is merged into ^TMP("GMRA",$J) (ORWDAL32.m:124).
  # GMRANKA="YES" is NKA^GMRAGUI1 (ORWDAL32.m:127); otherwise
  # UPDATE^GMRAGUI1 (ORWDAL32.m:128). The new #120.8 IEN stays inside
  # UPDATE and is not returned — re-read the list to find the entry.
  module Allergy
    extend self

    NOT_ASSESSED_SENTINEL = "^No Allergy Assessment" # ORQQAL.m:12
    NKA_SENTINEL          = "^No Known Allergies"    # ORQQAL.m:13

    # EDITSAVE^ORWDAL32 (ORWDAL32.m:119). Return type is a single value.
    SAVE_ALLERGY_RPC = "ORWDAL32 SAVE ALLERGY"

    # UPDATE^GMRAGUI1 reads these named subscripts (GMRAGUI1.m:104).
    # GMRAGNT is "agent^variable pointer" (GMRAGUI1.m:89, :106).
    REQUIRED_FIELDS = %i[
      agent agent_pointer type nature originator originated_at observed_or_historical
    ].freeze

    # "-1^Patient already has a <agent> reaction entered.  No duplicates allowed."
    # (GMRAGUI1.m:89). Two spaces before "No".
    DUPLICATE_REPLY = %r{\A-1\^Patient already has a .+ reaction entered\.  No duplicates allowed\.\z}

    # MESS^GMRAGUI1 joins the two sentences with two spaces
    # (GMRAGUI1.m:160 stock / :157 FOIA).
    LOCK_REPLY = "-1^Another user is editing this patient's allergy information.  " \
                 "Please refresh/review the patient's information before proceeding."

    # NKA^GMRAGUI1 (GMRAGUI1.m:75).
    ACTIVE_ALLERGIES_REPLY = "-1^Patient has active allergies - can't mark as NKA"

    # NKA^GMRAGUI1 file-header and record locks (GMRAGUI1.m:76, :80).
    ASSESSMENT_UPDATE_REPLY = "-1^Unable to update assessment - try again."

    # "0" or "0^<note IEN>" (GMRAGUI1.m:149 stock / :147 FOIA).
    SUCCESS_REPLY = /\A0(?:\^(\d+))?\z/

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

    # Add an allergy. ORALIEN "" is new: UPDATE sets NEW='$G(GMRAIEN)
    # (GMRAGUI1.m:88) and EDITSAVE passes that ORALIEN through
    # (ORWDAL32.m:128). OREDITED carries GMRAGNT, GMRATYPE, GMRANATR,
    # GMRAORIG, GMRAORDT, GMRAOBHX (GMRAGUI1.m:104), optional
    # GMRASYMP(n) (GMRAGUI1.m:120 stock / :118 FOIA) and GMRACMTS(n)
    # (GMRAGUI1.m:118 stock / :116 FOIA) as two-level subscripts, and
    # optional GMRARDT / GMRASEVR (GMRAGUI1.m:137 stock / :135 FOIA).
    #
    #   save(dfn, allergy) => { success: true, note_ien: Integer or nil }
    #                     or { success: false, error:, message: }
    def save(dfn, allergy)
      patient = canonical_dfn(dfn)
      return invalid_dfn unless patient

      missing = absent_required(allergy)
      return missing_allergy(missing) unless missing.empty?

      dispatch(patient, edited_list(allergy))
    end

    # Record no known allergies. OREDITED("GMRANKA")="YES" selects
    # NKA^GMRAGUI1 (ORWDAL32.m:127, GMRAGUI1.m:68); ORALIEN is "".
    # Already-NKA leaves ORY at the 0 EDITSAVE set (ORWDAL32.m:125,
    # GMRAGUI1.m:74).
    def no_known_allergies(dfn)
      patient = canonical_dfn(dfn)
      return invalid_dfn unless patient

      dispatch(patient, { "GMRANKA" => "YES" })
    end

    private

    def response_lines(response)
      case response
      when nil then []
      when String then response.split(/\r?\n/)
      else Array(response)
      end.map { |line| DataMapper.strip_recordset_separators(line.to_s) }
    end

    # A DFN is a positive canonical integer: a positive Integer, or a
    # string of digits with no leading zero and no trailing junk
    # ("12abc" is not 12).
    def canonical_dfn(value)
      case value
      when Integer then value.positive? ? value.to_s : nil
      when String then value.match?(/\A[1-9]\d*\z/) ? value : nil
      end
    end

    def absent_required(allergy)
      return REQUIRED_FIELDS unless allergy.is_a?(Hash)

      REQUIRED_FIELDS.select { |field| blank_field?(allergy[field]) }
    end

    def blank_field?(value)
      value.nil? || value.to_s.strip.empty?
    end

    def invalid_dfn
      { success: false, error: :invalid_dfn, message: "a positive DFN is required" }
    end

    def missing_allergy(fields)
      { success: false, error: :missing_fields, message: "missing #{fields.join(", ")}" }
    end

    # GMRASYMP(n)="ien^text^FileMan date" and GMRACMTS(n)=comment
    # (GMRAGUI1.m:120, :118 stock). Array keys are the two-level
    # subscripts CiaClient#m_subscript / XwbClient#m_subscript encode.
    def edited_list(allergy)
      edited = {
        "GMRAGNT" => "#{allergy[:agent]}^#{allergy[:agent_pointer]}",
        "GMRATYPE" => allergy[:type],
        "GMRANATR" => allergy[:nature],
        "GMRAORIG" => allergy[:originator].to_s,
        "GMRAORDT" => allergy[:originated_at],
        "GMRAOBHX" => allergy[:observed_or_historical]
      }
      allergy[:symptoms]&.each_with_index do |symptom, idx|
        edited[[ "GMRASYMP", idx + 1 ]] = "#{symptom[:ien]}^#{symptom[:text]}^#{symptom[:date]}"
      end
      allergy[:comments]&.each_with_index do |line, idx|
        edited[[ "GMRACMTS", idx + 1 ]] = line
      end
      edited["GMRARDT"] = allergy[:reaction_date] if allergy[:reaction_date]
      edited["GMRASEVR"] = allergy[:severity] if allergy[:severity]
      edited
    end

    def dispatch(dfn, edited)
      raw = RpmsRpc.client.call_rpc(SAVE_ALLERGY_RPC, "", dfn, edited)
      classify_reply(raw)
    end

    def classify_reply(raw)
      text = reply_text(raw)
      return { success: false, error: :empty_reply, message: "" } if text.nil?

      if (match = text.match(SUCCESS_REPLY))
        note = match[1]
        return { success: true, note_ien: note ? note.to_i : nil }
      end

      if text.start_with?("-1^")
        return { success: false, error: error_for(text), message: text }
      end

      { success: false, error: :malformed_reply, message: text }
    end

    # [], "", and nil are empty. Any other non-string is not a single-value
    # ORY (return type 1) and fails closed as malformed.
    def reply_text(raw)
      return nil if raw.nil? || raw == "" || raw == []
      return raw if raw.is_a?(String)

      raw.to_s
    end

    def error_for(text)
      case text
      when DUPLICATE_REPLY then :duplicate
      when LOCK_REPLY then :locked
      when ACTIVE_ALLERGIES_REPLY then :active_allergies
      when ASSESSMENT_UPDATE_REPLY then :assessment_update_failed
      else :rejected
      end
    end
  end
end
