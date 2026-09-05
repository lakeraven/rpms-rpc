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

    # Get-or-create a visit — the visit-create path, replacing the removed
    # placeholder visit-create wire name (docs/RPC_COVERAGE.md provenance
    # notes). Runs the registered BEHOENCX FETCH with its CREATE flag
    # (FETCH^BEHOENCX; params/reply on :encounter_get_or_create). Creation
    # descends to GETVISIT^BSDAPI4, the IHS PCC visit-creation API —
    # GETVISIT^BEHOENCX itself never creates (rpms-ops
    # docs/REGISTRATION_RPC_CONTRACTS.md §3).
    #
    #   location_ien:     hospital location IEN
    #   datetime:         FileMan datetime (Date/Time formatted here, or a
    #                     preformatted string)
    #   service_category: visit service category code (e.g. "A")
    #   provider_ien:     optional provider to associate/restrict by
    #   create:           1 = create if not found (default), -1 = always,
    #                     0 = lookup only (FETCH^BEHOENCX CREATE flag)
    #
    # Returns the parsed visit context (:visit_ien, :visit_id,
    # :location_name, :provider_name, ...) merged with success: true,
    # { success: false, error: } when the server reports an error row, or
    # nil when the broker gives no response at all.
    def create(dfn, location_ien:, datetime:, service_category:, provider_ien: nil, create: 1)
      return nil if dfn.nil?

      vstr = visit_string(location_ien, datetime, service_category)
      result = DataMapper.encounter_get_or_create.fetch_one(
        dfn.to_s, vstr, provider_ien.to_s, create.to_s
      )
      return nil if result.nil?
      return { success: false, error: result[:error] } unless result[:visit_ien]

      result.merge(success: true)
    end

    # VSTR "LOC;FM_DATETIME;SVC_CAT" per VSTR2VIS^BEHOENCX.
    def visit_string(location_ien, datetime, service_category)
      dt = datetime
      dt = FilemanDateParser.format_datetime(dt) if dt.is_a?(Date) || dt.is_a?(Time)
      "#{location_ien};#{dt};#{service_category}"
    end
  end
end
