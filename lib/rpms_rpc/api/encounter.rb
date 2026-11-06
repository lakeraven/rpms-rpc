# frozen_string_literal: true

require_relative "../shape"
require_relative "../mappings"

module RpmsRpc
  module Encounter
    extend self
    extend Shape::Declarable

    # List recent appointments for a patient.
    # Underlying RPC: ORWPT APPTLST
    def for_patient(dfn)
      DataMapper.patient_appointments.fetch_many(dfn.to_s)
    end
    shape :for_patient, resource: "encounters", verb: "GET", path: "/patients/{dfn}/encounters"

    # Texts BEHOXQPC returns when that component is present or not required,
    # keyed by component. Encounter.open drops a CHKVISIT row only when
    # :message, stripped of surrounding whitespace, is exactly one of the
    # texts for its own component (the component is stripped too).
    #
    #   POV  "Visit has POV"                      (NOPOV, BEHOXQPC.m:10, code -2)
    #   E&M  "Visit has E&M code"                 (NEEDSEMC, BEHOXQPC.m:59, code -2)
    #   E&M  "E&M code not required."             (NEEDSEMC, BEHOXQPC.m:55, code -7)
    #   E&M  "Provider does not require E&M code" (NEEDSEMC, BEHOXQPC.m:61, code -5)
    CHKVISIT_SATISFIED_TEXTS = {
      "POV" => [
        "Visit has POV"
      ].freeze,
      "E&M" => [
        "Visit has E&M code",
        "E&M code not required.",
        "Provider does not require E&M code"
      ].freeze
    }.freeze

    # Service categories that are not an encounter with this site: VISITLST
    # leaves X (ancillary) out unless told otherwise (BEHOENCX.m:233).
    VISIT_EXCLUDED_CATEGORIES = "X"
    # Dates a patient's whole history falls between. VISITLST's own default
    # window is a site's recent days, and the visit a client names by id can
    # be older than that.
    VISIT_HISTORY_START = "2000101"
    VISIT_HISTORY_END = "3991231"
    # VISITLST's IGPFLG: visits only, not appointments pending check-in.
    VISITS_ONLY = "1"

    # The patient's visits, newest first: the V file parent every V POV, V CPT
    # and V MEASUREMENT hangs from, where #for_patient is the appointment list.
    # Each is { visit_ien:, location_ien:, location:, service_category:,
    # category:, datetime:, locked:, provider_ien:, provider:, standalone: }.
    # Underlying RPC: BEHOENCX VISITLST
    def visits(dfn)
      DataMapper.encounter_visit_list
        .fetch_many(dfn.to_s, VISIT_HISTORY_START, VISIT_HISTORY_END, "", VISIT_EXCLUDED_CATEGORIES, VISITS_ONLY)
        .filter_map { |row| visit_with_identifiers(row) }
    end
    shape :visits, resource: "encounters", verb: "GET", path: "/patients/{dfn}/encounters/visits"

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
    #   4. BEHOENCX CHKVISIT(IEN) (CHKVISIT^BEHOENCX, BEHOENCX.m:329-337).
    #      CHKVISIT replies empty when BEHOXQPC is absent (BEHOENCX.m:330)
    #      and otherwise always one POV and one E&M row. CV1 overwrites
    #      piece 1 (the status code) with the component name, so the text
    #      is the only signal. :missing_components is nil unless both of
    #      those rows came back: the check was not established and must
    #      never be read as "nothing missing". [] means both components
    #      were reported satisfied. When both rows are present, a row is
    #      left out only when its message, stripped of surrounding
    #      whitespace, is one of CHKVISIT_SATISFIED_TEXTS for its own
    #      component (stripped). A nil message stays, and so do the missing
    #      texts ("Notification was delivered", "Notification exists",
    #      "Notification is disabled"), the not-checked texts ("Visit has
    #      no note", "No primary provider", "Bad visit specifier") and any
    #      unknown text. Fail closed: the API never hides a component the
    #      server did not say is present. Live visit 1 on
    #      bcer-9.0-20261012-e7923a4-ydb returned "POV^Visit has POV"
    #      although the visit has a POV. CHKVISIT is not side-effect free:
    #      when a visit has a note and lacks a POV or E&M code,
    #      SEND^BEHOXQPC files an alert to the primary provider
    #      (BEHOXQPC.m:64-74). A nil :missing_components does not make open
    #      return nil.
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

      rows = DataMapper.encounter_chkvisit.fetch_many(key)
      components = rows.map { |row| row[:component]&.strip }
      missing = if components.include?("POV") && components.include?("E&M")
        rows.reject do |row|
          message = row[:message]
          texts = CHKVISIT_SATISFIED_TEXTS[row[:component]&.strip]
          !message.nil? && texts&.include?(message.strip)
        end
      end

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
    # A row without a visit IEN is not a visit.
    private def visit_with_identifiers(row)
      location_ien, _date, category, visit_ien = row[:visit_string].to_s.split(";", -1)
      return if visit_ien.to_s.empty?

      row.except(:visit_string).merge(
        visit_ien: visit_ien.to_i, location_ien: location_ien.to_i, service_category: category
      )
    end

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
