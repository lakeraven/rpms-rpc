# frozen_string_literal: true

require_relative "../mappings"
require_relative "../shape"
require_relative "ddr_fileman"

module RpmsRpc
  # Symbolic API for visit purpose-of-visit (POV) entry — visit-level diagnosis
  # codes with optional modifiers (primary/secondary, injury cause, etc.).
  # Underlying RPCs: BGOVPOV RECENT, BGOVPOV GET (GET^BGOVPOV — BGOVPOV.m:106),
  # BGOVPOV SET (SET^BGOVPOV — BGOVPOV.m:291).
  module Pov
    extend self
    extend Shape::Declarable

    POV_FILE = "9000010.07"

    # The diagnoses recorded on the patient's visits, in one read: { ien:,
    # visit_ien:, visit_date:, facility:, icd_code:, icd_name:, narrative:,
    # onset_date:, snomed_ct: }. visit_date and onset_date are MM/DD/YYYY text,
    # as RPMS sends them. Underlying RPC: BGOVPOV RECENT
    def for_patient(dfn)
      return [] if invalid_id?(dfn)

      DataMapper.patient_pov_list.fetch_many(dfn.to_s)
    end
    shape :for_patient, resource: "purposes-of-visit", verb: "GET", path: "/patients/{dfn}/purposes-of-visit"

    # The diagnoses on one visit, with what BGOVPOV RECENT leaves out:
    # episodicity, modifier, stage, injury, primary or secondary, provider,
    # qualifiers, the problem it was recorded against and laterality.
    # Underlying RPC: BGOVPOV GET (GET^BGOVPOV, FORMAT 0, the detailed row).
    #
    #   for_visit(visit_ien) => [{ ien:, visit_date:, facility_code:, facility:,
    #                              icd_code:, episodicity:, narrative:, modifier:,
    #                              onset_date:, stage:, revisit:, cause:,
    #                              injury_date:, external_cause:, place_of_injury:,
    #                              primary_or_secondary:, provider_name:, visit_ien:,
    #                              visit_locked:, asthma_control:, snomed_description:,
    #                              provider_text:, qualifiers:, problem_ien:,
    #                              e_code:, icd_name:, icd_ien:, normal_abnormal:,
    #                              laterality:, fracture: }, ...]
    #
    # ien is the V POV (#9000010.07) IEN; the dates are Dates; qualifiers
    # and fracture are the "|"-joined pieces as sent. snomed_description is
    # the SNOMED concept's description: the row does not carry its concept
    # ID (rpms-rpc#927). A -n^text reply raises Client::RpcError.
    def for_visit(visit_ien)
      return [] if invalid_id?(visit_ien)

      DataMapper.visit_povs.fetch_many!("#{visit_ien}^^")
    end
    shape :for_visit, resource: "purposes-of-visit", verb: "GET", path: "/visits/{visit_ien}/purposes-of-visit"

    # File a visit diagnosis from a problem-list entry (BGOVPOV SET). The
    # problem is required: GETDATA^BGOVPOV2 walks ^AUPNPROB(PROB,13,...) with
    # the problem sent, and with none the build errors with a null subscript
    # (rpms-rpc#922). A call without modifiers[:problem_ien] is refused with
    # the failure hash, naming it, before anything is sent. A visit diagnosis
    # with no problem goes through Encounter.save (BEHOENPC SAVE). On the
    # pinned build the diagnosis also needs its SNOMED concept (:snomed_ct):
    # without one SET2^BGOVPOV2 refuses the ICD code (-1092).
    #
    # INP layout (BGOVPOV.m:285-286; parsed :298-303): VPOV IEN[1]^
    # Visit IEN[2]^Problem IEN[3]^Patient IEN[4]^Prov Text[5]^
    # Descriptive CT[6]^SNOMED CT[7]^ICD code[8]^Primary/Secondary[9]^
    # Provider IEN[10]^asthma[11]^norm/abn[12]^laterality[13]^fracture[14].
    # The injury-cause diagnosis rides the separate INJ formal, piece 1
    # (BGOVPOV.m:288,291).
    #
    # Recognized modifiers: :primary/:secondary (piece 9), :problem_ien (3),
    # :descriptive_ct (6), :snomed_ct (7), :provider_duz (10), :laterality
    # (13), :fracture (14), :injury_cause (INJ piece 1).
    def add(dfn, visit_ien, diagnosis_code, narrative:, modifiers: {})
      return failure if invalid_id?(dfn) || invalid_id?(visit_ien) || blank?(diagnosis_code)
      if invalid_id?(modifiers[:problem_ien])
        return failure.merge(error: "modifiers[:problem_ien] is required: BGOVPOV SET files a diagnosis from a problem-list entry")
      end

      diagnosis_role =
        if modifiers[:primary] then "P"
        elsif modifiers[:secondary] then "S"
        else ""
        end

      inp = [
        "",                             # VPOV IEN — empty for a new entry
        visit_ien.to_s,
        modifiers[:problem_ien].to_s,
        dfn.to_s,
        narrative.to_s,
        modifiers[:descriptive_ct].to_s,
        modifiers[:snomed_ct].to_s,
        diagnosis_code.to_s,
        diagnosis_role,
        modifiers[:provider_duz].to_s,
        "",                             # asthma control
        "",                             # norm/abn (also a NORM formal)
        modifiers[:laterality].to_s,
        modifiers[:fracture].to_s
      ].join("^")
      inj = modifiers[:injury_cause].to_s

      raw = DataMapper.pov_set.fetch_scalar(inp, "", inj)

      saved_ien = raw.to_s.match(/\A\d+/)&.to_s&.to_i
      {
        success: !saved_ien.nil? && saved_ien.positive?,
        ien: saved_ien,
        raw: raw
      }
    rescue RpmsRpc::Client::FrameTooLongError => e
      # A value the wire would mis-frame is refused before anything is sent
      # (#472); this API's contract is a failure hash, so it says why.
      failure.merge(error: e.message)
    end
    shape :add, resource: "purposes-of-visit", verb: "POST", path: "/patients/{dfn}/purposes-of-visit"

    # Remove a visit diagnosis: BGOVPOV DEL (DEL^BGOVPOV, BGOVPOV.m:196).
    # With problem_ien, the build first takes the visit off that problem's
    # visit list, so the problem no longer reads as used on it. The V POV
    # (#9000010.07) is read first, and nothing is sent unless its .02 is
    # this patient (:not_found, :wrong_patient); it is read again after,
    # and an entry still on file is :not_filed. A visit the build will not
    # change answers -n^text (CHKVISIT^BGOUTL).
    #
    # Returns { success:, ien:, raw: }, plus error: on a refusal.
    def delete(dfn, pov_ien, problem_ien: nil)
      return failure if invalid_id?(dfn) || invalid_id?(pov_ien)
      return failure.merge(error: "problem_ien must be a positive integer") if problem_ien && invalid_id?(problem_ien)

      mapping = DataMapper.pov_remove
      mapping.in_context do
        patient = pov_patient(pov_ien)
        next failure.merge(error: patient) if patient.is_a?(Symbol)
        next failure.merge(error: :wrong_patient) unless patient == dfn.to_s

        # Client called directly: DEL answers "" on success, which
        # fetch_scalar would collapse into nil (indistinguishable from broker
        # silence, and silence must never read as a delete).
        raw = RpmsRpc.client.call_rpc(mapping.rpc_name, pov_ien.to_s, problem_ien.to_s)
        next { success: false, ien: pov_ien.to_i, raw: raw } unless DataMapper.write_accepted?(raw)
        next { success: true, ien: pov_ien.to_i, raw: raw } if pov_patient(pov_ien) == :not_found

        { success: false, ien: pov_ien.to_i, raw: raw, error: :not_filed }
      end
    end
    shape :delete, resource: "purposes-of-visit", verb: "DELETE", path: "/patients/{dfn}/purposes-of-visit/povs/{pov_ien}"

    private

    # The V POV's .02 PATIENT, internal; :not_found when GETS^DIQ answers
    # an error or no field for the entry; :unreadable when the read cannot
    # be trusted.
    def pov_patient(ien)
      entry = DdrFileman.gets_entry(file: POV_FILE, iens: "#{ien},", fields: ".02", flags: "I")
      return :unreadable if entry.nil? || entry[:malformed] || entry[:stray] || entry[:altered]
      return :not_found if entry[:error] || entry[:fields].empty?

      entry[:fields].dig(".02", :internal).to_s
    end

    def failure
      { success: false, ien: nil, raw: nil }
    end

    def invalid_id?(value)
      value.nil? || value.to_s.strip.empty? || value.to_i <= 0
    end

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end
  end
end
