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
    # location, provider, datetime, service category, lock state, and a
    # missing-components report.
    #
    # Composed as the server expects (BEHOENCX.m):
    #   1. BEHOENCX GETVISIT(IEN)  -> LOC^VDT^SVC^PAT^VID^LOCKED (lines 5,8-15)
    #   2. the EXTENDED visit string "LOC;VDT;SVC;IEN" from that reply
    #   3. BEHOENCX FETCH(DFN,VSTR,PRV="",CREATE=0) -> LOCNAME^LOCABBR^ROOMBED^
    #      PROVIEN^PROVNAME^VISITIEN^VISITID^LOCKED^ERRORTXT (lines 30-47).
    #      With the IEN in the VSTR, VSTR2VIS resolves the visit directly
    #      (line 107) — no 60-minute FNDVIS window — and CREATE=0 can never
    #      add one. FETCH used to be sent the visit IEN as its only param,
    #      which landed in DFN and left VSTR undefined (#211).
    #   4. BEHOENCX CHKVISIT(IEN) -> COMPONENT^MESSAGE rows (lines 329-337)
    #
    # Returns nil when the visit doesn't exist, when the FETCH companion
    # response is missing or reports an error instead of a visit (incomplete
    # hydration is treated as a miss rather than silently returning partial
    # data), or when the visit belongs to a different DFN than the caller
    # passed (prevents cross-patient visit access — checked here from
    # GETVISIT's PAT piece, and again server-side by VIS2VSTR, line 118).
    #
    # Output keys are stable for consumers; each now comes from the piece
    # that carries it. :location_ien is GETVISIT's LOC (FETCH has no location
    # IEN — its piece 4 is the provider IEN, exposed as :provider_ien).
    # :status is the same value as :service_category — GETVISIT's SVC piece —
    # kept under the name consumers already read; no BEHOENCX reply carries
    # an encounter status. :ward is gone: nothing on either wire is a ward
    # (the pieces so labelled were the visit id, now :visit_id).
    def open(dfn, visit_ien)
      return nil if dfn.nil? || visit_ien.nil?

      key = visit_ien.to_s
      visit = DataMapper.encounter_visit.fetch_one(key)
      return nil if visit.nil?

      # Cross-patient guard: BEHOENCX GETVISIT returns the visit's owning DFN
      # in piece 4. If the caller passed a different DFN, reject.
      if visit[:patient_dfn] && visit[:patient_dfn].to_i != dfn.to_i
        return nil
      end

      vstr = visit_string(visit[:location_ien], visit[:datetime_raw], visit[:service_category],
                          visit_ien: visit_ien)
      fetch = DataMapper.encounter_fetch.fetch_one(dfn.to_s, vstr, "", "0")
      return nil if fetch.nil? || fetch[:visit_ien].nil?

      missing = DataMapper.encounter_chkvisit.fetch_many(key)

      {
        visit_ien:          visit_ien.to_i,
        patient_dfn:        (visit[:patient_dfn] || dfn).to_i,
        location_ien:       visit[:location_ien],
        location:           fetch[:location_name],
        clinic_abbrev:      fetch[:location_abbrev],
        room_bed:           fetch[:room_bed],
        provider:           fetch[:provider_name],
        provider_ien:       fetch[:provider_ien],
        datetime_raw:       visit[:datetime_raw],
        service_category:   visit[:service_category],
        status:             visit[:service_category],
        visit_id:           visit[:visit_id] || fetch[:visit_id],
        locked:             visit[:locked],
        missing_components: missing
      }
    end

    # Get-or-create a visit — the visit-create path, replacing the removed
    # placeholder visit-create wire name (docs/rpcs.md, BHDPTRPC provenance
    # notes). Runs the registered BEHOENCX FETCH with its CREATE flag
    # (FETCH^BEHOENCX; params/reply on :encounter_fetch). Creation
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
      result = DataMapper.encounter_fetch.fetch_one(
        dfn.to_s, vstr, provider_ien.to_s, create.to_s
      )
      return nil if result.nil?
      return { success: false, error: result[:error] } unless result[:visit_ien]

      result.merge(success: true)
    end

    # VSTR "LOC;FM_DATETIME;SVC_CAT" per VSTR2VIS^BEHOENCX (BEHOENCX.m:107),
    # or the EXTENDED form "LOC;FM_DATETIME;SVC_CAT;VISITIEN" when visit_ien
    # is given: VSTR2VIS then takes that IEN and skips the FNDVIS search.
    # A Time or DateTime formats with its clock; a plain Date has none, so it
    # formats as a FileMan date (a Date answers no #hour, and asking raised).
    def visit_string(location_ien, datetime, service_category, visit_ien: nil)
      dt = datetime
      if dt.is_a?(Time) || dt.is_a?(DateTime)
        dt = FilemanDateParser.format_datetime(dt)
      elsif dt.is_a?(Date)
        dt = FilemanDateParser.format_date(dt)
      end
      vstr = "#{location_ien};#{dt};#{service_category}"
      visit_ien.nil? ? vstr : "#{vstr};#{visit_ien}"
    end
  end
end
