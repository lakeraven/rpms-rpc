# frozen_string_literal: true

require_relative "../shape"
require_relative "../mappings"
require_relative "ddr_fileman"

module RpmsRpc
  # That a list was reviewed with the patient on a visit (allergies,
  # problems, medications), through the RPCs VueCentric's review buttons file
  # it with: BGOVUPD SET and GET (BGOVUPD, BGO COMPONENTS patch 36 on the
  # bcer-9.0 build). Recorded in V UPDATED/REVIEWED (#9000010.54), one entry
  # per review, typed by a CLINICAL REVIEW ACTION (#9999999.101) such as
  # ALLERGY LIST REVIEWED, with the signed-on user as who did it.
  module ClinicalReview
    extend self
    extend Shape::Declarable

    ACTION_FILE = "9999999.101"
    ALLERGY_LIST_REVIEWED = "ALLERGY LIST REVIEWED"
    IEN = /\A[1-9]\d*\z/

    # File a review on a visit of the patient, as the signed-on user.
    #
    #   record(dfn, visit_ien, action: "ALLERGY LIST REVIEWED")
    #   => { success:, ien:, raw:, error: }
    #
    # SET^BGOVUPD takes ACTION IEN ^ ^ DFN ^ VISIT STRING ^ EVENT DATE ^
    # PROVIDER and answers V UPDATED/REVIEWED IEN ^ VISIT IEN, or -n^text. It
    # resolves the visit string with VSTR2VIS^BEHOENCX, CREATING a visit when
    # the string names none, and does not check that a named visit is the
    # patient's. So the visit is read first (BEHOENCX GETVISIT), and one that
    # is not this patient's, or is locked, is refused before anything is
    # filed; the string sent names only that visit (";;;VISIT IEN").
    def record(dfn, visit_ien, action: ALLERGY_LIST_REVIEWED)
      return refusal(:invalid_id) unless ien?(dfn) && ien?(visit_ien)

      visit = DataMapper.encounter_visit.fetch_one(visit_ien.to_s)
      return refusal(:wrong_patient) unless visit && visit[:patient_dfn] == dfn.to_i
      return refusal(:locked) if visit[:locked]

      action_ien = action_ien(action)
      return refusal(:unknown_action) unless action_ien

      raw = DataMapper.clinical_review_set.fetch_scalar("#{action_ien}^^#{dfn}^;;;#{visit_ien}^^")
      ien, filed_visit = raw.to_s.split("^", 3)
      return { success: true, ien: ien.to_i, raw: raw, error: nil } if ien.to_s.match?(IEN) && filed_visit == visit_ien.to_s

      refusal(:refused, raw: raw)
    end
    shape :record, resource: "clinical-reviews", verb: "POST", path: "/patients/{dfn}/clinical-reviews"

    # The reviews filed on a visit.
    #
    #   for_visit(dfn, visit_ien) => [{ ien:, action:, kind:, entered_by:, ... }, ...]
    #
    # GET^BGOVUPD with DFN ^ VISIT IEN answers, per entry not marked in error,
    # IEN ^ ACTION IEN~ACTION ^ KIND (A allergy, P problem, M medication) ^
    # VISIT DATE ^ DATE ENTERED ^ ENTERED BY ^ EVENT DATE ^ ENCOUNTER PROVIDER,
    # dates and names as FileMan prints them.
    def for_visit(dfn, visit_ien)
      return [] unless ien?(dfn) && ien?(visit_ien)

      DataMapper.clinical_reviews.fetch_many("#{dfn}^#{visit_ien}")
    end
    shape :for_visit, resource: "clinical-reviews", verb: "GET", path: "/patients/{dfn}/clinical-reviews/visits/{visit_ien}"

    private

    # The CLINICAL REVIEW ACTION's IEN, found by its exact name.
    def action_ien(name)
      listed = DdrFileman.lister(file: ACTION_FILE, fields: ".01", flags: "IP", xref: "B", part: name.to_s, max: "10")
      rows = Array(listed && listed[:entries]).select { |row| row[:pieces]&.first == name.to_s }
      rows.first[:ien].to_s if rows.size == 1
    end

    def refusal(error, raw: nil)
      { success: false, ien: nil, raw: raw, error: error }
    end

    def ien?(value) = !value.nil? && value.to_s.match?(IEN)
  end
end
