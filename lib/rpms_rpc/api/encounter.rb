# frozen_string_literal: true

require "date"
require_relative "../shape"
require_relative "../mappings"
require_relative "ddr_fileman"

module RpmsRpc
  module Encounter
    extend self
    extend Shape::Declarable

    # List recent appointments for a patient.
    # Underlying RPC: ORWPT APPTLST. Rows are APPTTIME^LOCIEN^LOCNAME^EXTSTATUS
    # (APPTLST^ORWPT). When the scheduling read fails, APPTLST answers one
    # row with no time, from SDA^ORQRY01: "^Error encountered^Error
    # encountered" for VAERR 1 (no such patient, or the appointment API
    # refused the request) and "^Database is unavailable^Database is
    # unavailable" for VAERR 2. A row with no appointment time is not an
    # appointment, so the read fails closed: it raises Client::RpcError
    # naming the text, and never lists a visit at a location called "Error
    # encountered" (#679).
    def for_patient(dfn)
      rows = DataMapper.patient_appointments.fetch_many(dfn.to_s)
      failed = rows.find { |row| row[:datetime].nil? }
      if failed
        raise Client::RpcError, "ORWPT APPTLST could not read appointments for patient #{dfn}: #{failed[:location]}"
      end

      rows
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

    # The providers on one of the patient's visits: BEHOENCX GETPRV
    # (GETPRV^BEHOENCX), from V PROVIDER (#9000010.06).
    #
    #   providers(dfn, visit_ien, primary_only: false)
    #     => [{ duz:, name:, primary:, event_datetime: }, ...]
    #
    # The visit is named by IEN in the visit string's fourth piece
    # (VSTR2VIS^BEHOENCX), so no location or time need match; a visit of
    # another patient answers [] (VIS2VSTR refuses it). primary_only: true
    # sends PRI and keeps the primary provider only.
    def providers(dfn, visit_ien, primary_only: false)
      return [] unless [ dfn, visit_ien ].all? { |id| id.to_s.match?(/\A[1-9]\d*\z/) }

      mapping = DataMapper.visit_providers
      client = RpmsRpc.client
      reply = mapping.in_context(client) { client.call_rpc(mapping.rpc_name, dfn.to_s, ";;;#{visit_ien}", primary_only ? "1" : "") }
      lines = Array(reply).map(&:to_s).reject(&:empty?)
      raise Client::RpcError, RpmsRpc.sanitize_error("BEHOENCX GETPRV refused: #{lines.first}") if lines.first && DataMapper.error_row?(lines.first)

      mapping.parse_many(lines)
    end
    shape :providers, resource: "encounters", verb: "GET", path: "/patients/{dfn}/encounters/{visit_ien}/providers"

    # A provider's activity and travel time on a visit: BGOVTM GET
    # (GET^BGOVTM), the V ACTIVITY TIME (#9000010.19) entry on the visit's
    # AD index whose ENCOUNTER PROVIDER (12;4) is the provider, as
    # { ien:, activity_minutes:, travel_minutes: } (.01 and .04). nil when
    # the provider has no entry on the visit (the routine answers 0^0^0).
    # A -N^text reply (no visit, no provider, a provider not on file)
    # raises Client::RpcError.
    def activity_time(visit_ien, provider_duz)
      return nil unless [ visit_ien, provider_duz ].all? { |id| id.to_s.match?(/\A[1-9]\d*\z/) }

      raw = DataMapper.visit_activity_time.lines!("#{visit_ien}^#{provider_duz}").first.to_s
      ien, activity, travel = raw.split("^", -1)
      raise Client::RpcError, "BGOVTM GET answered #{raw.inspect}" unless ien.to_s.match?(/\A\d+\z/)
      return nil if ien == "0"

      { ien: ien.to_i, activity_minutes: activity.to_s.empty? ? nil : activity.to_i, travel_minutes: travel.to_s.empty? ? nil : travel.to_i }
    end
    shape :activity_time, resource: "encounters", verb: "GET", path: "/encounters/{visit_ien}/activity-time"

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

      missing = missing_components(DataMapper.encounter_chkvisit.fetch_many(key))

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
    shape :open, resource: "encounters", verb: "POST", path: "/patients/{dfn}/encounters/{visit_ien}/open"

    # Get-or-create a visit — the visit-create path, replacing the removed
    # placeholder visit-create wire name (docs/rpcs.md, BHDPTRPC provenance
    # notes). Runs the registered BEHOENCX FETCH with its CREATE flag
    # (FETCH^BEHOENCX; params/reply on :encounter_fetch). Creation
    # descends to GETVISIT^BSDAPI4, the IHS PCC visit-creation API —
    # GETVISIT^BEHOENCX itself never creates (openrpms
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
    shape :create, resource: "encounters", verb: "POST", path: "/patients/{dfn}/encounters"

    # File an encounter in one call through BEHOENPC SAVE (SAVE^BEHOENPC,
    # rpms-rpc#921): the visit, its V POVs, V CPTs, V HEALTH FACTORs and the
    # primary V PROVIDER, as VueCentric does. The PCC list is
    #
    #   HDR^0^^<loc>;<fm datetime>;<category>     VST^DT^<fm datetime>
    #   VST^PT^<dfn>   VST^HL^<loc>   VST^VC^<category>   PRV^<duz>^^^^1
    #   POV+^<icd>^^^^<1|0>^^^<snomed>^<narrative>   (1 primary, 0 secondary)
    #   CPT+^<cpt>^^^^^<quantity>   HF+^<factor ien>^^^^<duz>
    #
    # then "0" and the location, the two formals the routine requires and
    # does not use (BEHOENPC.m:6-10).
    #
    #   diagnoses:      [{ icd:, snomed:, narrative:, primary: }]
    #   procedures:     [{ cpt:, quantity: 1 }]
    #   health_factors: [{ ien: }]   (the HEALTH FACTOR #9999999.64 IEN)
    #   datetime:       a Time/DateTime (formatted here) or a FileMan string
    #
    # Every diagnosis is linked to the problem list by the routine itself:
    # POV^BEHOENPC calls $$PROBLST^BEHOENP2 unconditionally, which reuses the
    # patient's undeleted problem for the SNOMED concept or files a new one,
    # and stores it in the V POV's .16. The gem sends no problem-list RPC; it
    # reports the problem each diagnosis was linked to. A diagnosis with no
    # SNOMED concept is refused before sending: the routine subscripts on it
    # (rpms-rpc#704). So is any value carrying ^ ; or |, which would shift a
    # piece, the visit string or the "text|description" narrative.
    #
    # The save answers 0 and names nothing it filed, so the visit (BEHOENCX
    # FETCH with CREATE=0, which can never add one), V POVs (BGOVPOV GET),
    # V CPTs (BGOVCPT GET), V HEALTH FACTORs (BGOVHF GET) and V PROVIDERs
    # (BEHOENCX GETPRV) are read before and after. Only a row that was not
    # there before, on this visit, is this call's: "+" always adds a row, and
    # a rerun on the same day files onto the visit already there.
    #
    # A diagnosis's new V POV is the one whose provider text is the narrative
    # sent (in order among equal narratives), a procedure's the new V CPT of
    # its code and quantity, a health factor's the new V HF of that factor.
    # A new row on the visit that no request explains (another session's
    # write between the reads, or the build filing more than was sent) makes
    # the result :ambiguous, never success, and is listed in :unattributed.
    # The primary provider is a state, not a row: it is read back when the
    # visit shows the provider sent as primary, with pre_existing: true when
    # it already did before the save.
    #
    # Returns { success:, raw:, error:, may_have_filed:, visit_ien:,
    # diagnoses: [{ ien:, icd:, snomed:, problem_ien: }], procedures: [{ ien:,
    # cpt: }], health_factors: [{ ien:, factor_ien: }], provider: { duz:,
    # primary:, pre_existing: }, not_filed: [...], unattributed: [...] }.
    # success is the visit and every requested entry read back. error is
    # :invalid (a blank required argument, or an entry that is not a Hash of
    # the documented keys with the values it needs), :delimiter or
    # :missing_snomed (nothing sent); :snapshot_failed (the read before the
    # save failed, nothing sent); :no_reply, :refused (the server's -N^text
    # row, in raw; what filed before the failing line is read back and
    # reported) or :unexpected_reply; :no_visit,
    # :partial (some entry not read back, or a diagnosis read back with no
    # problem link; what did file is still reported), :ambiguous, or
    # :read_back_failed (the save was sent and the read after it failed;
    # read_back_error says why), or :save_failed (the save was sent and no
    # reply came back: a dropped connection, a timeout or an M error).
    #
    # A SNOMED concept that maps to more than one ICD files one V POV per
    # code (ADDICD^BEHOENP2), all with the diagnosis's narrative and problem;
    # the extra ones are reported under the diagnosis as additional: [{ ien:,
    # icd: }]. Each health factor IEN is read from HEALTH FACTORS
    # (#9999999.64 .01, DDR GETS ENTRY DATA) before anything is filed: the
    # build would file one it has no entry for as a dangling pointer in the
    # patient's record (rpms-rpc#928), so such an IEN is refused, :invalid,
    # named in not_filed (reason: :unknown_health_factor), and nothing is
    # sent; a read that cannot be trusted is :snapshot_failed. Should one
    # still read back with no factor, it is reported in not_filed the same
    # way, never as filed. Sending the primary provider on
    # an existing visit makes any other primary provider on it secondary
    # (STORE^BEHOENPC sets .04 to P on the one sent). may_have_filed is true whenever BEHOENPC
    # SAVE was sent, including when the connection failed during it: the
    # caller must not assume nothing was filed.
    def save(dfn, location_ien:, datetime:, service_category:, provider_duz:,
             diagnoses: [], procedures: [], health_factors: [])
      diagnoses = Array(diagnoses)
      procedures = Array(procedures)
      health_factors = Array(health_factors)
      malformed = malformed_entries(diagnoses, procedures, health_factors)
      return save_result(error: :invalid, not_filed: malformed) unless malformed.empty?

      fm_datetime = save_datetime(datetime)
      at_fault = delimiter_entries(dfn, location_ien, fm_datetime, service_category, provider_duz,
                                   diagnoses, procedures, health_factors)
      return save_result(error: :delimiter, not_filed: at_fault) unless at_fault.empty?

      unless [ dfn, location_ien, provider_duz ].all? { |id| id.to_s.strip.match?(/\A[1-9]\d*\z/) } &&
             !service_category.to_s.strip.empty? && fm_datetime
        return save_result(error: :invalid)
      end

      missing = diagnoses.select { |d| d[:snomed].to_s.strip.empty? }
      return save_result(error: :missing_snomed, not_filed: missing.map { |d| diagnosis_entry(d) }) unless missing.empty?

      incomplete = incomplete_entries(diagnoses, procedures, health_factors)
      return save_result(error: :invalid, not_filed: incomplete) unless incomplete.empty?

      vstr = "#{location_ien};#{fm_datetime};#{service_category}"
      pcc = save_list(dfn, location_ien, fm_datetime, service_category, provider_duz,
                      diagnoses, procedures, health_factors)
      mapping = DataMapper.encounter_save
      client = RpmsRpc.client
      sent = false
      replied = false
      raw = nil
      mapping.in_context(client) do
        unknown = begin
          unknown_health_factors(health_factors)
        rescue Client::FrameTooLongError, Client::RpcError, Client::ParseError => e
          next save_result(error: :snapshot_failed, raw: RpmsRpc.sanitize_error(e.message))
        end
        next save_result(error: :snapshot_failed, raw: unknown) if unknown.is_a?(String)
        next save_result(error: :invalid, not_filed: unknown) unless unknown.empty?

        before = begin
          save_snapshot(dfn, vstr)
        rescue Client::FrameTooLongError, Client::RpcError, Client::ParseError => e
          next save_result(error: :snapshot_failed, raw: RpmsRpc.sanitize_error(e.message))
        end
        sent = true
        raw = save_reply(client.call_rpc(mapping.rpc_name, pcc, "0", location_ien.to_s))
        replied = true
        next save_result(error: :no_reply, may_have_filed: true) if raw.nil?
        if DataMapper.error_row?(raw)
          next refused(raw, save_snapshot(dfn, vstr), before, provider_duz, diagnoses, procedures, health_factors)
        end
        next save_result(error: :unexpected_reply, raw: raw, may_have_filed: true) unless raw == "0"

        after = save_snapshot(dfn, vstr)
        read_back(raw, before, after, provider_duz, diagnoses, procedures, health_factors)
      end
    rescue Client::FrameTooLongError => e
      save_result(error: e.message, may_have_filed: sent)
    rescue RpmsRpc::Error => e
      raise unless sent

      save_result(error: replied ? :read_back_failed : :save_failed, raw: raw, may_have_filed: true,
                  read_back_error: RpmsRpc.sanitize_error("#{e.class.name.split('::').last}: #{e.message}"))
    end
    shape :save, resource: "encounters", verb: "POST", path: "/patients/{dfn}/encounters/pcc"

    private

    def save_datetime(datetime)
      case datetime
      when Time, DateTime then FilemanDateParser.format_datetime(datetime)
      when Date then FilemanDateParser.format_date(datetime)
      when String then fileman_datetime?(datetime) ? datetime : nil
      end
    end

    # A FileMan date or date-time a calendar has: YYYMMDD[.HHMMSS], the year
    # counted from 1700, a real month and day, and a clock time up to 24:00:00.
    def fileman_datetime?(value)
      md = value.match(/\A(\d{3})(\d{2})(\d{2})(?:\.(\d{1,6}))?\z/)
      return false unless md && Date.valid_date?(md[1].to_i + 1700, md[2].to_i, md[3].to_i)
      return true if md[4].nil?

      hh, mm, ss = md[4].ljust(6, "0").scan(/\d\d/).map(&:to_i)
      (hh < 24 && mm < 60 && ss < 60) || (hh == 24 && mm.zero? && ss.zero?)
    end

    def save_result(error:, raw: nil, not_filed: [], visit_ien: nil, diagnoses: [], procedures: [],
                    health_factors: [], provider: nil, may_have_filed: false, unattributed: [], read_back_error: nil)
      result = { success: false, raw: raw, error: error, may_have_filed: may_have_filed, visit_ien: visit_ien,
                 diagnoses: diagnoses, procedures: procedures, health_factors: health_factors, provider: provider,
                 not_filed: not_filed, unattributed: unattributed }
      read_back_error ? result.merge(read_back_error: read_back_error) : result
    end

    SAVE_KEYS = {
      diagnosis: %i[icd snomed narrative primary],
      procedure: %i[cpt quantity],
      health_factor: %i[ien]
    }.freeze
    private_constant :SAVE_KEYS

    # Entries that are not a Hash of the documented keys: refused, never
    # dropped, so a misspelt key cannot silently send an empty piece.
    def malformed_entries(diagnoses, procedures, health_factors)
      { diagnosis: diagnoses, procedure: procedures, health_factor: health_factors }.flat_map do |kind, list|
        list.each_with_index.filter_map do |entry, index|
          next { kind: kind, index: index, reason: :not_a_hash } unless entry.is_a?(Hash)

          unknown = entry.keys - SAVE_KEYS.fetch(kind)
          { kind: kind, index: index, reason: :unknown_keys, keys: unknown } unless unknown.empty?
        end
      end
    end

    POSITIVE_INTEGER = /\A[1-9]\d*\z/
    private_constant :POSITIVE_INTEGER

    # Entries missing a value the PCC line needs: an ICD code, a CPT code, a
    # quantity that is a positive integer, a health factor IEN.
    def incomplete_entries(diagnoses, procedures, health_factors)
      entries = []
      diagnoses.each { |d| entries << diagnosis_entry(d).merge(reason: :missing_icd) if d[:icd].to_s.strip.empty? }
      procedures.each do |p|
        entries << { kind: :procedure, cpt: p[:cpt], reason: :missing_cpt } if p[:cpt].to_s.strip.empty?
        unless p[:quantity].nil? || p[:quantity].to_s.match?(POSITIVE_INTEGER)
          entries << { kind: :procedure, cpt: p[:cpt], reason: :bad_quantity }
        end
      end
      health_factors.each do |h|
        entries << { kind: :health_factor, factor_ien: h[:ien], reason: :bad_ien } unless h[:ien].to_s.match?(POSITIVE_INTEGER)
      end
      entries
    end

    HEALTH_FACTORS_FILE = "9999999.64"
    private_constant :HEALTH_FACTORS_FILE

    # The requested health factors HEALTH FACTORS has no entry for, each as
    # not_filed names it; or, when a read cannot be trusted (no reply, or
    # one DdrFileman marks malformed, stray or altered), the text saying so.
    def unknown_health_factors(health_factors)
      health_factors.each_with_object([]) do |h, unknown|
        entry = DdrFileman.gets_entry(file: HEALTH_FACTORS_FILE, iens: "#{h[:ien]},", fields: ".01", flags: "I")
        if entry.nil? || entry[:malformed] || entry[:stray] || entry[:altered]
          return "DDR GETS ENTRY DATA on HEALTH FACTORS #{h[:ien]} could not be read"
        end
        next unless entry[:error] || entry.dig(:fields, ".01", :internal).to_s.strip.empty?

        unknown << { kind: :health_factor, factor_ien: h[:ien], reason: :unknown_health_factor }
      end
    end

    def diagnosis_entry(diagnosis)
      { kind: :diagnosis, icd: diagnosis[:icd], snomed: diagnosis[:snomed] }
    end

    SAVE_DELIMITER = /[\^;|]/
    private_constant :SAVE_DELIMITER

    # The entries whose values carry a delimiter, each named as not_filed
    # names it; the visit's own arguments are named as kind: :visit.
    def delimiter_entries(dfn, location_ien, fm_datetime, service_category, provider_duz,
                          diagnoses, procedures, health_factors)
      bad = ->(*values) { values.any? { |v| v.to_s.match?(SAVE_DELIMITER) } }
      entries = []
      { dfn: dfn, location_ien: location_ien, datetime: fm_datetime, service_category: service_category,
        provider_duz: provider_duz }.each { |field, value| entries << { kind: :visit, field: field } if bad.call(value) }
      diagnoses.each { |d| entries << diagnosis_entry(d) if bad.call(d[:icd], d[:snomed], d[:narrative]) }
      procedures.each { |p| entries << { kind: :procedure, cpt: p[:cpt] } if bad.call(p[:cpt], p[:quantity]) }
      health_factors.each { |h| entries << { kind: :health_factor, factor_ien: h[:ien] } if bad.call(h[:ien]) }
      entries
    end

    def save_list(dfn, location_ien, fm_datetime, service_category, provider_duz,
                  diagnoses, procedures, health_factors)
      lines = [
        "HDR^0^^#{location_ien};#{fm_datetime};#{service_category}",
        "VST^DT^#{fm_datetime}",
        "VST^PT^#{dfn}",
        "VST^HL^#{location_ien}",
        "VST^VC^#{service_category}",
        "PRV^#{provider_duz}^^^^1"
      ]
      diagnoses.each do |d|
        lines << "POV+^#{d[:icd]}^^^^#{d[:primary] ? 1 : 0}^^^#{d[:snomed].to_s.strip}^#{d[:narrative]}"
      end
      procedures.each { |p| lines << "CPT+^#{p[:cpt]}^^^^^#{(p[:quantity] || 1).to_i}" }
      health_factors.each { |h| lines << "HF+^#{h[:ien]}^^^^#{provider_duz}" }
      lines.each_with_index.to_h { |line, i| [ i + 1, line ] }
    end

    # The save's reply as one line: a scalar, or the first line of a list.
    def save_reply(reply)
      return nil if reply.nil?

      line = reply.is_a?(Array) ? reply.map(&:to_s).reject(&:empty?).first : reply.to_s
      return nil if line.nil?

      line = DataMapper.strip_recordset_separators(line).strip
      return line if reply.is_a?(String) || reply.size == 1 || DataMapper.error_row?(line)

      reply.map(&:to_s).join("\n")
    end

    # What the visit named by vstr holds, read through the gem's readers. A
    # FETCH with CREATE=0 never adds a visit.
    def save_snapshot(dfn, vstr)
      mapping = DataMapper.encounter_fetch
      fetched = mapping.parse_one(mapping.lines!(dfn.to_s, vstr, "", "0").first)
      if fetched && !fetched[:error].to_s.strip.empty?
        raise Client::RpcError, RpmsRpc.sanitize_error("BEHOENCX FETCH: #{fetched[:error]}")
      end

      visit = fetched && fetched[:visit_ien].to_i.positive? ? fetched[:visit_ien].to_i : nil
      {
        visit: visit,
        povs: visit ? DataMapper.visit_povs.fetch_many!("#{visit}^^") : [],
        cpts: DataMapper.procedure_list.fetch_many!(dfn.to_s),
        hfs: DataMapper.patient_health_factors.fetch_many!("#{dfn}^^"),
        providers: visit ? providers(dfn, visit) : []
      }
    end

    # The rows on the visit that the save added.
    # A V CPT is keyed by IEN and code: BGOVCPT GET also lists V DENTAL, V
    # PROCEDURE and V TRANSACTION rows, whose IENs are another file's.
    def new_rows(before, after, key)
      id = key == :cpts ? ->(row) { [ row[:ien].to_i, row[:cpt_code].to_s ] } : ->(row) { row[:ien].to_i }
      seen = before[key].map(&id)
      after[key].select { |row| row[:visit_ien].to_i == after[:visit] && !seen.include?(id.(row)) }
    end

    def read_back(raw, before, after, provider_duz, diagnoses, procedures, health_factors)
      visit = after[:visit]
      return save_result(error: :no_visit, raw: raw, may_have_filed: true, not_filed: [ { kind: :visit } ]) unless visit

      # New V POVs pair with the diagnoses in the order sent: "+" adds rows
      # in list order (STORE^BEHOENPC), so IENs rise with it. They are not
      # matched by code: POV^BEHOENPC files the ICD its SNOMED concept maps
      # to, which may differ from the ICD sent, and BGOVPOV GET's row carries
      # the concept's description, not its ID, on the pinned build.
      not_filed = []
      unattributed = []

      # A diagnosis's rows: its V POV and, for a concept that maps to more
      # than one ICD, the extra V POVs ADDICD^BEHOENP2 files right after it
      # with the same narrative and problem.
      pov_groups = pov_groups(new_rows(before, after, :povs))
      pov_missing = []
      filed_diagnoses = match_rows(pov_groups, diagnoses, pov_missing) do |group, d|
        group.first[:provider_text].to_s.strip == d[:narrative].to_s.strip
      end.map do |group, d|
        row = group.first
        problem = row[:problem_ien].to_s.match?(POSITIVE_INTEGER) ? row[:problem_ien].to_i : nil
        not_filed << { kind: :problem, icd: d[:icd], snomed: d[:snomed] } unless problem
        { ien: row[:ien].to_i, icd: row[:icd_code], snomed: d[:snomed], problem_ien: problem,
          additional: group.drop(1).map { |extra| { ien: extra[:ien].to_i, icd: extra[:icd_code] } } }
      end
      not_filed.unshift(*pov_missing.map { |e| diagnosis_entry(e[:request]) })
      claimed = filed_diagnoses.flat_map { |d| [ d[:ien], *d[:additional].map { |a| a[:ien] } ] }
      unattributed.concat(pov_groups.flatten.reject { |row| claimed.include?(row[:ien].to_i) }
                                    .map { |row| { kind: :diagnosis, ien: row[:ien].to_i } })

      cpt_rows = new_rows(before, after, :cpts)
      cpt_missing = []
      filed_procedures = match_rows(cpt_rows, procedures, cpt_missing) do |row, p|
        row[:cpt_code].to_s == p[:cpt].to_s && row[:quantity].to_i == (p[:quantity] || 1).to_i
      end.map { |row, p| { ien: row[:ien].to_i, cpt: p[:cpt] } }
      not_filed.concat(cpt_missing.map { |e| { kind: :procedure, cpt: e[:request][:cpt] } })
      unattributed.concat(leftover(cpt_rows, filed_procedures, :procedure))

      hf_rows = new_rows(before, after, :hfs)
      hf_missing = []
      matched_factors = match_rows(hf_rows, health_factors, hf_missing) do |row, h|
        row[:factor_ien].to_i == h[:ien].to_i
      end
      dangling, named = matched_factors.partition { |row, _h| row[:factor].to_s.strip.empty? }
      filed_factors = named.map { |row, h| { ien: row[:ien].to_i, factor_ien: h[:ien] } }
      not_filed.concat(dangling.map { |row, h| { kind: :health_factor, factor_ien: h[:ien], ien: row[:ien].to_i, reason: :unknown_health_factor } })
      not_filed.concat(hf_missing.map { |e| { kind: :health_factor, factor_ien: e[:request][:ien] } })
      unattributed.concat(leftover(hf_rows, matched_factors.map { |row, _h| { ien: row[:ien].to_i } }, :health_factor))

      primary_of = ->(rows) { rows.any? { |row| row[:duz].to_i == provider_duz.to_i && row[:primary] } }
      provider = primary_of.(after[:providers]) ? { duz: provider_duz.to_i, primary: true, pre_existing: primary_of.(before[:providers]) } : nil
      not_filed << { kind: :provider, duz: provider_duz } unless provider

      error = if !not_filed.empty? then :partial
      elsif !unattributed.empty? then :ambiguous
      end
      result = save_result(error: error, raw: raw, not_filed: not_filed, visit_ien: visit, may_have_filed: true,
                           diagnoses: filed_diagnoses, procedures: filed_procedures,
                           health_factors: filed_factors, provider: provider, unattributed: unattributed)
      result.merge(success: error.nil?)
    end

    # A -N^text reply. SAVE^BEHOENPC stops at the line that failed and keeps
    # the lines before it (the visit, the provider, earlier entries), so what
    # did file is read back and reported; the error stays :refused.
    def refused(raw, after, before, provider_duz, diagnoses, procedures, health_factors)
      unless after[:visit]
        not_filed = [ { kind: :visit } ] + diagnoses.map { |d| diagnosis_entry(d) } +
                    procedures.map { |p| { kind: :procedure, cpt: p[:cpt] } } +
                    health_factors.map { |h| { kind: :health_factor, factor_ien: h[:ien] } } +
                    [ { kind: :provider, duz: provider_duz } ]
        return save_result(error: :refused, raw: raw, may_have_filed: true, not_filed: not_filed)
      end

      read_back(raw, before, after, provider_duz, diagnoses, procedures, health_factors)
        .merge(success: false, error: :refused, raw: raw)
    end

    # New V POVs in IEN order, a row with the same narrative and problem as
    # the row before it joining that row's group (ADDICD^BEHOENP2's extra
    # codes for one concept).
    def pov_groups(rows)
      rows.sort_by { |row| row[:ien].to_i }.each_with_object([]) do |row, groups|
        last = groups.last&.first
        same = last && !row[:problem_ien].to_s.empty? && row[:problem_ien].to_s == last[:problem_ien].to_s &&
               row[:provider_text].to_s.strip == last[:provider_text].to_s.strip
        same ? groups.last << row : groups << [ row ]
      end
    end

    # New rows on the visit that no request claimed.
    def leftover(rows, claimed, kind)
      taken = claimed.map { |entry| entry[:ien] }
      rows.reject { |row| taken.include?(row[:ien].to_i) }.map { |row| { kind: kind, ien: row[:ien].to_i } }
    end

    # Pairs each request with the first unclaimed row the block accepts, in
    # request order. A request with no row goes to `missing` as
    # { kind: :unmatched, request: }.
    def match_rows(rows, requests, missing)
      available = rows.dup
      requests.filter_map do |request|
        index = available.index { |row| yield(row, request) }
        if index
          [ available.delete_at(index), request ]
        else
          missing << { kind: :unmatched, request: request }
          nil
        end
      end
    end

    public

    # VSTR "LOC;FM_DATETIME;SVC_CAT" per VSTR2VIS^BEHOENCX (BEHOENCX.m:107),
    # or the EXTENDED form "LOC;FM_DATETIME;SVC_CAT;VISITIEN" when visit_ien
    # is given: VSTR2VIS then takes that IEN and skips the FNDVIS search.
    # A Time or DateTime formats with its clock; a plain Date has none, so it
    # formats as a FileMan date (a Date answers no #hour, and asking raised).
    # A row without a visit IEN is not a visit.
    # CHKVISIT's rows less the ones it reports satisfied; nil unless both
    # the POV and the E&M row came back (see open, step 4).
    private def missing_components(rows)
      components = rows.map { |row| row[:component]&.strip }
      return nil unless components.include?("POV") && components.include?("E&M")

      rows.reject do |row|
        message = row[:message]
        texts = CHKVISIT_SATISFIED_TEXTS[row[:component]&.strip]
        !message.nil? && texts&.include?(message.strip)
      end
    end

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
