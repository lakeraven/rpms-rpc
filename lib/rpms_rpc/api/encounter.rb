# frozen_string_literal: true

module RpmsRpc
  module Encounter
    extend self

    # List recent appointments for a patient.
    # Underlying RPC: ORWPT APPTLST
    def for_patient(dfn)
      DataMapper.patient_appointments.fetch_many(dfn.to_s)
    end

    # Open an active encounter — hydrates the visit context the chart needs:
    # location, provider, datetime, status, ward, and a missing-components report.
    #
    # Returns nil when the visit doesn't exist, when the BEHOENCX FETCH companion
    # response is missing (incomplete hydration is treated as a miss rather than
    # silently returning partial data), or when the visit belongs to a different
    # DFN than the caller passed (prevents cross-patient visit access).
    #
    # Underlying RPCs (composed): BEHOENCX GETVISIT, BEHOENCX FETCH, BEHOENCX CHKVISIT
    def open(dfn, visit_ien)
      return nil if dfn.nil? || visit_ien.nil?

      key = visit_ien.to_s
      visit = DataMapper.encounter_visit.fetch_one(key)
      return nil if visit.nil?

      # Cross-patient guard: BEHOENCX GETVISIT returns the visit's owning DFN
      # in field 3. If the caller passed a different DFN, reject.
      if visit[:patient_dfn] && visit[:patient_dfn].to_i != dfn.to_i
        return nil
      end

      fetch = DataMapper.encounter_fetch.fetch_one(key)
      return nil if fetch.nil?

      missing = DataMapper.encounter_chkvisit.fetch_many(key)

      {
        visit_ien:          visit_ien.to_i,
        patient_dfn:        (visit[:patient_dfn] || dfn).to_i,
        location_ien:       fetch[:location_ien] || visit[:location_ien],
        location:           fetch[:clinic_name],
        clinic_abbrev:      fetch[:clinic_abbrev],
        provider:           fetch[:provider],
        datetime_raw:       visit[:datetime_raw],
        status:             visit[:status],
        ward:               fetch[:ward] || visit[:ward],
        missing_components: missing
      }
    end
  end
end
