# frozen_string_literal: true

require_relative "../mappings"
require_relative "ddr_fileman"

module RpmsRpc
  # Symbolic API for PCC measurement entry — distinct from clinical vitals
  # (Vital module / BEHOVM). Measurements are typed observations (height,
  # weight, BMI, head circumference, etc.) recorded against an open encounter.
  # Units should be UCUM codes (e.g. "kg", "cm", "kg/m2") where the
  # downstream consumer needs interoperable units.
  # Underlying RPC: BGOVUPD SET with MSR record type.
  #
  # Reads (.for_visit / .latest / .find / .newest_by_type) compose
  # existing registered RPCs so the FHIR layer can build Observation +
  # Provenance without new M code:
  #   BGOVMSR GET / BGOVMSR LAST  — measurement rows carrying the visit IEN
  #   ORQQVI VITALS (FASTVIT)     — newest measurement per type
  #   BEHOENCX GETVISIT           — the visit's SERVICE CATEGORY (#9000010
  #                                 .07) + visit date (date fallback)
  #   DDR GETS ENTRY DATA         — #9000010.01 field 2 (ENTERED IN ERROR)
  #                                 + 1201 event date / .07 entered time
  #   BEHOVM2 VUNITS              — display units for the raw stored value
  module Measurement
    extend self

    RECORD_TYPE = "MSR"

    # V MEASUREMENT file (#9000010.01, ^AUPNVMSR).
    V_MEASUREMENT_FILE = "9000010.01"

    # Visit SERVICE CATEGORY (#9000010 field .07, ^AUPNVSIT(IEN,0) piece 7)
    # → measurement capture mode for FHIR Provenance. Code set cited from
    # the corpus: PXRHS01.m:14-26 (A/H/I/C/T/N/S/O/E/R/D/X) and
    # APCDEIN.m:85 (IHS input set, adds M:TELEMEDICINE).
    #
    # :office   — patient physically at a facility encounter; the value was
    #             captured where it was measured.
    # :reported — no in-person measurement at capture time (telecom /
    #             telemedicine / historical event / chart abstraction);
    #             treat as patient- or secondarily-reported.
    # anything else (N=NOT FOUND, X=ANCILLARY PACKAGE DAILY DATA, blank,
    # garbage) → :unknown.
    SERVICE_CATEGORY_CAPTURE_MODE = {
      "A" => :office,   # AMBULATORY            (PXRHS01.m:14)
      "H" => :office,   # HOSPITALIZATION       (PXRHS01.m:15)
      "I" => :office,   # IN HOSPITAL           (PXRHS01.m:16)
      "S" => :office,   # DAY SURGERY           (PXRHS01.m:21)
      "O" => :office,   # OBSERVATION           (PXRHS01.m:22)
      "R" => :office,   # NURSING HOME          (PXRHS01.m:24)
      "D" => :office,   # DAILY HOSPITALIZATION DATA (PXRHS01.m:25) /
      #                   DAY SURGERY (APCDEIN.m:85) — in-facility either way
      "T" => :reported, # TELECOMMUNICATIONS    (PXRHS01.m:18)
      "M" => :reported, # TELEMEDICINE          (APCDEIN.m:85)
      "E" => :reported, # EVENT (HISTORICAL)    (PXRHS01.m:23)
      "C" => :reported  # CHART REVIEW          (PXRHS01.m:17)
    }.freeze

    # Classify a service-category code. Nil-safe; unrecognized → :unknown.
    def capture_mode_for(service_category)
      SERVICE_CATEGORY_CAPTURE_MODE.fetch(service_category.to_s.strip.upcase, :unknown)
    end

    # Core V MEASUREMENT fields for the by-IEN DDR read. Field numbers
    # cited from corpus readers of #9000010.01:
    #   .01 MEASUREMENT TYPE — internal is a #9999999.07 pointer whose .01
    #        is the abbreviation ("WT"), so the external form is that
    #        abbreviation (EIE^BEHOVM2: BEHOVM2.m:65-66 —
    #        "$$GET1^DIQ(9000010.01,+BEHDATA,.01,\"I\")" then
    #        "$$GET1^DIQ(9999999.07,CHK,.01)=\"WT\"")
    #   .02 PATIENT — internal is the DFN (APCDBMI.m:20)
    #   .03 VISIT — internal is the visit IEN (APCDBMI.m:22, BHSMEA.m:87)
    #   .04 VALUE, 1201 event date/time, 2 ENTERED IN ERROR — the exact
    #        field set BTIUPCC4.m:19 reads (".03;.04;1201;2")
    #   .07 TIME ENTERED — administrative entry time, NOT the clinical
    #        time: the writer files .07 = $$NOW at save and 1201 = the
    #        taken date (SAVE^BEHOENPC: BEHOENPC.m:274,286-287), and the
    #        canonical reader labels piece 7 "Time entered"
    #        (VMEA^BPXRMPX: BPXRMPX.m:70). See resolve_date.
    CORE_FIELDS = ".01;.02;.03;.04;2;1201;.07"

    # One V MEASUREMENT by IEN, fully decorated — the read behind
    # id-addressed FHIR lookups (Observation/{ien}, Provenance target
    # search) where only the measurement IEN is known. Returns the same
    # hash shape as .for_visit rows plus :patient_dfn, or nil when the
    # IEN is invalid/unknown or the DDR read fails.
    def find(measurement_ien)
      return nil if invalid_id?(measurement_ien)

      fields = core_fields(measurement_ien)
      return nil if fields.nil?

      type = external(fields, ".01")
      return nil if type.nil?

      visit_memo = {}
      visit_ien = internal(fields, ".03")&.to_i
      visit = visit_for(visit_ien, visit_memo)
      category = visit && visit[:service_category]
      date, date_source = resolve_date(fields, visit)
      {
        measurement_ien:  measurement_ien.to_i,
        patient_dfn:      internal(fields, ".02")&.to_i,
        type:             type,
        value:            internal(fields, ".04"),
        units:            units_for(type, {}),
        date:             date,
        date_source:      date_source,
        visit_ien:        visit_ien,
        service_category: category,
        capture_mode:     capture_mode_for(category),
        entered_in_error: internal(fields, "2") == "1"
      }
    end

    # The patient's NEWEST measurement per vital type (optionally within a
    # date range), decorated for Provenance. This deliberately replaces an
    # earlier `.history` method that claimed full patient history from the
    # same index — a false claim: the registered "ORQQVI VITALS" RPC
    # dispatches to FASTVIT^ORQQVI (.broker_dumps_8994_20260607.txt:565),
    # which returns at most ONE row per type — the newest in range
    # (ORQQVI.m:64-91, per-type `Q:OK` at ORQQVI.m:170-171).
    #
    # NO registered RPC provides a verifiable full V MEASUREMENT history
    # for a patient today:
    #   - "ORQQVI VITALS FOR DATE RANGE" (VITALS^ORQQVI, dump line 795 —
    #     the :vitals_for_date_range mapping) IS full history over a
    #     range, but reads only GMRV #120.5 (ORQQVI.m:13-16, no IHS
    #     branch) and returns #120.5 IENs, which must NOT be fed to the
    #     #9000010.01 DDR decoration this module does.
    #   - "BEHOVM GRID" is IHS-aware full-range (QRYMSR^BEHOVM walks
    #     ^AUPNVMSR) but returns a grid-subscripted global whose flattened
    #     wire shape is unverified against a populated capture.
    # Until one of those is captured against real populated data, this
    # module does not pretend to a history read.
    #
    # Each FASTVIT row is decorated per measurement via the CORE_FIELDS
    # DDR read (visit pointer + entered-in-error + clinical date),
    # BEHOENCX GETVISIT (service category + visit-date fallback) and
    # BEHOVM2 VUNITS (units). The decoration is valid on the IHS FASTVIT
    # branch (DUZ("AG")="I" — ORQQVI.m:96), where row IENs are
    # V MEASUREMENT IENs (ORQQVI.m:170-171). Sub-reads are memoized per
    # call and degrade to nil fields — :capture_mode :unknown,
    # :entered_in_error nil (unknown, never fabricated), :units nil (a
    # value without a source unit is for callers to drop, not guess).
    # Rows without a measurement IEN are dropped.
    def newest_by_type(dfn, start_date: nil, end_date: nil)
      return [] if invalid_id?(dfn)

      visit_memo = {}
      units_memo = {}
      params = [ dfn.to_s, fileman_bound(start_date), fileman_bound(end_date) ]
      params.pop while params.last.empty? && params.length > 1
      DataMapper.vitals.fetch_many(*params).filter_map do |row|
        ien = row[:measurement_ien]
        next if ien.nil?

        fields = core_fields(ien)
        type = (fields && external(fields, ".01")) || row[:type]
        visit_ien = fields && internal(fields, ".03")&.to_i
        visit = visit_for(visit_ien, visit_memo)
        category = visit && visit[:service_category]
        date, date_source = fields ? resolve_date(fields, visit) : [ row[:recorded_date], :wire ]
        {
          measurement_ien:  ien,
          patient_dfn:      dfn.to_i,
          type:             type,
          value:            row[:value],
          units:            units_for(type, units_memo),
          date:             date,
          date_source:      date_source,
          visit_ien:        visit_ien,
          service_category: category,
          capture_mode:     capture_mode_for(category),
          entered_in_error: fields.nil? ? nil : internal(fields, "2") == "1"
        }
      end
    end

    # All measurements recorded on one visit, decorated for Provenance.
    # Underlying RPC: BGOVMSR GET with INP "VISIT_IEN^0"
    # (GET^BGOVMSR: BGOVMSR.m:41-77; row shape in :visit_measurements).
    #
    # Returns [] for invalid input or no data; otherwise one hash per
    # measurement:
    #   { type:, value:, units:, date:, date_display:, measurement_ien:,
    #     visit_ien:, provider_name:, locked:, service_category:,
    #     capture_mode:, entered_in_error: }
    def for_visit(visit_ien)
      return [] if invalid_id?(visit_ien)

      rows = DataMapper.visit_measurements.fetch_many("#{visit_ien.to_i}^0")
      decorate(rows)
    end

    # Most recent measurement per type for a patient, decorated the same
    # way. Underlying RPC: BGOVMSR LAST with INP "DFN^TYPES^VISIT_IEN"
    # (LAST^BGOVMSR: BGOVMSR.m:3-35). `types` is a list of ^AUTTMSR
    # abbreviations (default server-side "HT;WT;TMP;BP;PU;RS;PA" —
    # BGOVMSR.m:12-13); `visit_ien` restricts to one visit.
    def latest(dfn, types: nil, visit_ien: nil)
      return [] if invalid_id?(dfn)

      inp = "#{dfn.to_i}^#{Array(types).join(';')}^#{visit_ien}"
      rows = DataMapper.latest_measurements.fetch_many(inp)
      decorate(rows)
    end

    def add(dfn, visit_ien, measurement_type, value, units:, qualifier: nil)
      return failure if invalid_id?(dfn) || invalid_id?(visit_ien) ||
                        blank?(measurement_type) || blank?(units) || value.nil?

      payload = [ RECORD_TYPE, measurement_type, value.to_s, units, qualifier.to_s ].join("^")
      raw = DataMapper.visit_data_save.fetch_scalar(dfn.to_s, visit_ien.to_s, payload)

      saved_ien = raw.to_s.match(/\A\d+/)&.to_s&.to_i
      {
        success: !saved_ien.nil? && saved_ien.positive?,
        ien: saved_ien,
        raw: raw
      }
    end

    private

    # Decorate BGOVMSR rows with service category + visit-date fallback
    # (per distinct visit), entered-in-error + clinical date (per
    # measurement), and units (per distinct type). Sub-reads are memoized
    # per call; any unreachable sub-read degrades to nil fields, never
    # raises.
    def decorate(rows)
      visit_memo = {}
      units_memo = {}
      rows.map do |row|
        visit = visit_for(row[:visit_ien], visit_memo)
        category = visit && visit[:service_category]
        fields = date_eie_fields(row[:measurement_ien])
        date, date_source = fields ? resolve_date(fields, visit) : [ nil, nil ]
        row.merge(
          units:             units_for(row[:type], units_memo),
          date:              date,
          date_source:       date_source,
          service_category:  category,
          capture_mode:      capture_mode_for(category),
          entered_in_error:  fields.nil? ? nil : internal(fields, "2") == "1"
        )
      end
    end

    # One visit row via BEHOENCX GETVISIT (registry:
    # .broker_dumps_8994_20260607.txt:2191 "BEHOENCX GETVISIT^GETVISIT^
    # BEHOENCX") — "hosp loc^visit date^service category^dfn^visit id^
    # locked" (GETVISIT^BEHOENCX: BEHOENCX.m:5,8-15). Carries both the
    # SERVICE CATEGORY (piece 3) and the visit date (piece 2 — the
    # measurement-date fallback). nil when the visit can't be read.
    def visit_for(visit_ien, memo)
      return nil if visit_ien.nil? || visit_ien.to_i <= 0

      memo.fetch(visit_ien) do
        memo[visit_ien] = DataMapper.encounter_visit.fetch_one(visit_ien.to_s)
      end
    end

    # ENTERED IN ERROR flag + date fields of one V MEASUREMENT, via the
    # registered generic FileMan read (DDR GETS ENTRY DATA — registry
    # .broker_dumps_8994_20260607.txt:16; GETSC^DDR2: DDR2.m:17-43).
    #   field 2    = ENTERED IN ERROR, set to 1 by the EIE store
    #                (EIE^BEHOVM2: BEHOVM2.m "BEHFDA(FNUM,BEHIENS,2)=1");
    #                read the same way BLDXRF^BEHOVM filters
    #                ("$$GET1^DIQ(9000010.01,VIEN,2,\"I\")").
    #   field 1201 = event date/time (clinical taken time)
    #   field .07  = TIME ENTERED (administrative — see resolve_date)
    # Returns the parsed field hash, or nil when the read is unreachable,
    # errored, or came back with NO parsed rows — an empty reply is
    # indistinguishable from a mis-grammared error string, so it degrades
    # to unknown rather than fabricating "not entered in error".
    def date_eie_fields(measurement_ien)
      return nil if measurement_ien.nil? || measurement_ien.to_i <= 0

      reply = DdrFileman.gets_entry(file: V_MEASUREMENT_FILE,
                                    iens: "#{measurement_ien.to_i},",
                                    fields: "2;.07;1201", flags: "IE")
      return nil if reply.nil? || reply[:error]

      fields = reply[:fields]
      fields.empty? ? nil : fields
    end

    # Resolve the clinical date of one measurement, honestly labeled with
    # its provenance (:date_source):
    #   :event   — #9000010.01 field 1201 EVENT DATE/TIME: what the writer
    #              files as the taken time (SAVE^BEHOENPC: BEHOENPC.m:275,
    #              286 "FLD(1201)=TAKEN").
    #   :visit   — 1201 empty; the VISIT's own date/time (#9000010 .01) —
    #              the canonical readers' fallback (VMEA^BPXRMPX:
    #              BPXRMPX.m:60-64; LAST^BGOVMSR: BGOVMSR.m:29 does the
    #              same).
    #   :entered — only .07 TIME ENTERED is available. That is the
    #              administrative save time, NOT the clinical time (the
    #              writer files .07 = $$NOW — BEHOENPC.m:274,287; the
    #              reader labels piece 7 "Time entered" — BPXRMPX.m:70).
    #              Surfaced labeled rather than silently substituted so
    #              callers can treat it as capture-time provenance only.
    #   nil      — no date recoverable.
    # 1201/.07 may carry a time ("3260607.1430") or be date-only
    # ("3260607") — both parse (to a midnight Time when date-only).
    def resolve_date(fields, visit)
      event = FilemanDateParser.parse_datetime_or_date(internal(fields, "1201"))
      return [ event, :event ] if event

      visit_date = visit && FilemanDateParser.parse_datetime_or_date(visit[:datetime_raw])
      return [ visit_date, :visit ] if visit_date

      entered = FilemanDateParser.parse_datetime_or_date(internal(fields, ".07"))
      return [ entered, :entered ] if entered

      [ nil, nil ]
    end

    # Coerce a Time/Date/FileMan-string range bound to the FileMan string
    # FASTVIT expects; nil → "" (server-side default, ORQQVI.m:74-78).
    def fileman_bound(value)
      case value
      when nil then ""
      when Time then FilemanDateParser.format_datetime(value)
      when Date then FilemanDateParser.format_date(value)
      else value.to_s
      end
    end

    # Display units for the raw stored value via BEHOVM2 VUNITS
    # (BEHOVM2.m:186-196 → UNITS^BEHOVM "US unit^LO^HI^Metric unit^LO^HI").
    # The stored value is US-units (BGOVMSR.m:60-63 converts lb→kg, in→cm,
    # F→C from it), so the US unit is the one that matches. nil on any miss.
    def units_for(type, memo)
      return nil if type.nil? || type.to_s.empty?

      memo.fetch(type) do
        units = DataMapper.vital_units.fetch_one(type.to_s)
        memo[type] = units && units[:us_unit]
      end
    end

    # All CORE_FIELDS of one V MEASUREMENT via the registered generic
    # FileMan read (DDR GETS ENTRY DATA — GETSC^DDR2: DDR2.m:17-43).
    # nil when the read is unreachable or errors.
    def core_fields(measurement_ien)
      reply = DdrFileman.gets_entry(file: V_MEASUREMENT_FILE,
                                    iens: "#{measurement_ien.to_i},",
                                    fields: CORE_FIELDS, flags: "IE")
      return nil if reply.nil? || reply[:error]

      fields = reply[:fields]
      fields.empty? ? nil : fields
    end

    def internal(fields, field_number)
      value = fields[field_number] && fields[field_number][:internal]
      value.nil? || value.empty? ? nil : value
    end

    def external(fields, field_number)
      value = fields[field_number] && fields[field_number][:external]
      value.nil? || value.empty? ? nil : value
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
