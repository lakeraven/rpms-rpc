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

    # The education on a visit that is linked to a problem (V PATIENT ED
    # field 1103), as VueCentric's problem-list education pane lists it.
    # Underlying RPC: BGOVPED2 GETPVED (GETPVED^BGOVPED2), one row per
    # entry on the visit's AD index that names a problem:
    #
    #   problem_linked(visit_ien)
    #     => [{ problem_ien:, topic:, documented_on:, provider_duz:, provider:, ien:,
    #           code:, subtopic:, level:, minutes:, readiness_to_learn:, mnemonic: }, ...]
    #
    # topic is the EDUCATION TOPICS (#9999999.09) name ("Acute
    # bronchitis-EXERCISE"), code and subtopic its two halves; level the
    # understanding; documented_on the event date (MM/DD/YYYY on the wire).
    # A -N^text reply raises Client::RpcError.
    def problem_linked(visit_ien)
      return [] if invalid_id?(visit_ien)

      DataMapper.problem_linked_education.lines!(visit_ien.to_s).map do |line|
        p = line.split("^", -1)
        raise Client::RpcError, "BGOVPED2 GETPVED answered #{line.inspect}" unless p[0].to_s.match?(/\A[1-9]\d*\z/) && p[5].to_s.match?(/\A[1-9]\d*\z/)

        { problem_ien: p[0].to_i, topic: blank(p[1]), documented_on: us_date(p[2]), provider_duz: p[3].to_i.positive? ? p[3].to_i : nil,
          provider: blank(p[4]), ien: p[5].to_i, code: blank(p[6]), subtopic: blank(p[7]), level: blank(p[8]),
          minutes: p[9].to_s.match?(/\A\d+\z/) ? p[9].to_i : nil, readiness_to_learn: blank(p[10]), mnemonic: blank(p[11]) }
      end
    end
    shape :problem_linked, resource: "patient-education", verb: "GET", path: "/patient-education/visits/{visit_ien}/problem-linked"

    private

    def blank(value)
      value.to_s.empty? ? nil : value
    end

    def us_date(value)
      month, day, year = value.to_s.split("/").map { |n| Integer(n, 10, exception: false) }
      return nil unless month && day && year

      Date.new(year, month, day)
    rescue Date::Error
      nil
    end

    def invalid_id?(value)
      value.nil? || !value.to_s.match?(/\A[1-9]\d*\z/)
    end
  end
end
