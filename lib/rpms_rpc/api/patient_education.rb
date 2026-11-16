# frozen_string_literal: true

require_relative "../shape"
require_relative "../mappings"

module RpmsRpc
  # The patient education recorded for a patient, as VueCentric's Patient
  # Education component lists it.
  # Underlying RPC: BGOVPED GET (GET^BGOVPED — BGOVPED.m:11).
  module PatientEducation
    extend self
    extend Shape::Declarable

    # V PATIENT ED (#9000010.16) entries, newest first, at most the site's
    # BGO PAT EDU MAX ENTRIES (200 when unset), for the patient or for one
    # of their visits.
    #
    #   for_patient(dfn, visit_ien: nil)
    #     => [{ topic:, visit_date:, level:, provider_name:, group_or_individual:,
    #           minutes:, cpt:, comment:, topic_category:, behavior:,
    #           objective_met:, visit_locked:, location:, ien:, visit_ien:,
    #           topic_ien:, location_ien:, provider_ien:, service_category:,
    #           icd_text:, readiness_to_learn:, icd_code:, entered_date: }, ...]
    #
    # topic is the display name GET^BGOVPED builds (the major topic and the
    # subtopic, "ANEMIA-COMPLICATIONS"); level is the understanding (GOOD,
    # FAIR, ...); the dates are Dates. A -n^text reply raises
    # Client::RpcError rather than reading as "no education".
    def for_patient(dfn, visit_ien: nil)
      return [] if invalid_id?(dfn)
      return [] if !visit_ien.nil? && invalid_id?(visit_ien)

      DataMapper.patient_education.fetch_many!("#{dfn}^#{visit_ien}")
    end
    shape :for_patient, resource: "patient-education", verb: "GET", path: "/patients/{dfn}/patient-education"

    private

    def invalid_id?(value)
      value.nil? || !value.to_s.match?(/\A[1-9]\d*\z/)
    end
  end
end
