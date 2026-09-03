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
  # Reads (.for_visit / .latest) compose four existing registered RPCs so
  # the FHIR layer can build Observation + Provenance without new M code:
  #   BGOVMSR GET / BGOVMSR LAST  — measurement rows carrying the visit IEN
  #   BEHOENCX GETVISIT           — the visit's SERVICE CATEGORY (#9000010 .07)
  #   DDR GETS ENTRY DATA         — #9000010.01 field 2 (ENTERED IN ERROR)
  #                                 + 1201/.07 (internal FileMan date/time)
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
    #   .07 date/time fallback (BEHOENP2.m:18-22 reads .07 then 1201)
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

      visit_ien = internal(fields, ".03")&.to_i
      category = service_category_for(visit_ien, {})
      raw_date = internal(fields, "1201") || internal(fields, ".07")
      {
        measurement_ien:  measurement_ien.to_i,
        patient_dfn:      internal(fields, ".02")&.to_i,
        type:             type,
        value:            internal(fields, ".04"),
        units:            units_for(type, {}),
        date:             FilemanDateParser.parse_datetime(raw_date) || FilemanDateParser.parse_date(raw_date),
        visit_ien:        visit_ien,
        service_category: category,
        capture_mode:     capture_mode_for(category),
        entered_in_error: internal(fields, "2") == "1"
      }
    end

    # A patient's full measurement history, decorated for Provenance.
    # ORQQVI VITALS is the index (verified MEASUREMENT_IEN^TYPE^DATETIME^
    # VALUE rows — VITALS^ORQQVI: ORQQVI.m:4-26; the ":vitals" mapping);
    # each row is then decorated per measurement via the CORE_FIELDS DDR
    # read (visit pointer + entered-in-error), BEHOENCX GETVISIT (service
    # category) and BEHOVM2 VUNITS (units). Sub-reads are memoized per
    # call and degrade to nil fields — :capture_mode :unknown,
    # :entered_in_error nil (unknown, never fabricated), :units nil (a
    # value without a source unit is for callers to drop, not guess).
    # The "^No vitals found." sentinel row (ORQQVI.m:24) has no
    # measurement IEN and is dropped.
    def history(dfn)
      return [] if invalid_id?(dfn)

      visit_memo = {}
      units_memo = {}
      DataMapper.vitals.fetch_many(dfn.to_s).filter_map do |row|
        ien = row[:measurement_ien]
        next if ien.nil?

        fields = core_fields(ien)
        type = (fields && external(fields, ".01")) || row[:type]
        visit_ien = fields && internal(fields, ".03")&.to_i
        category = service_category_for(visit_ien, visit_memo)
        {
          measurement_ien:  ien,
          patient_dfn:      dfn.to_i,
          type:             type,
          value:            row[:value],
          units:            units_for(type, units_memo),
          date:             row[:recorded_date],
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

    # Decorate BGOVMSR rows with service category (per distinct visit),
    # entered-in-error + internal date (per measurement), and units (per
    # distinct type). Sub-reads are memoized per call; any unreachable
    # sub-read degrades to nil fields, never raises.
    def decorate(rows)
      visit_memo = {}
      units_memo = {}
      rows.map do |row|
        category = service_category_for(row[:visit_ien], visit_memo)
        eie, date = eie_and_date(row[:measurement_ien])
        row.merge(
          units:             units_for(row[:type], units_memo),
          date:              date,
          service_category:  category,
          capture_mode:      capture_mode_for(category),
          entered_in_error:  eie
        )
      end
    end

    # Visit SERVICE CATEGORY via BEHOENCX GETVISIT — reply piece 3
    # (GETVISIT^BEHOENCX: BEHOENCX.m:4-16 "hosp loc^visit date^service
    # category^dfn^visit id^locked"). nil when the visit can't be read.
    def service_category_for(visit_ien, memo)
      return nil if visit_ien.nil? || visit_ien.to_i <= 0

      memo.fetch(visit_ien) do
        visit = DataMapper.encounter_visit.fetch_one(visit_ien.to_s)
        memo[visit_ien] = visit && visit[:service_category]
      end
    end

    # ENTERED IN ERROR flag + internal FileMan date/time for one
    # V MEASUREMENT, via the registered generic FileMan read
    # (DDR GETS ENTRY DATA — GETSC^DDR2: DDR2.m:17-43).
    #   field 2    = ENTERED IN ERROR, set to 1 by the EIE store
    #                (EIE^BEHOVM2: BEHOVM2.m "BEHFDA(FNUM,BEHIENS,2)=1");
    #                read the same way BLDXRF^BEHOVM filters
    #                ("$$GET1^DIQ(9000010.01,VIEN,2,\"I\")").
    #   field 1201 = event date/time, the date BEHOVM/BGOVMSR display
    #                (GETMSR^BEHOVM "DATE=+X12"; SET^BGOVMSR files it)
    #   field .07  = date/time fallback (BEHOENP2.m:18-22 reads .07 then
    #                1201; SET^BGOVMSR files both)
    # Returns [entered_in_error, date] — [nil, nil] when unreachable.
    def eie_and_date(measurement_ien)
      return [ nil, nil ] if measurement_ien.nil? || measurement_ien.to_i <= 0

      reply = DdrFileman.gets_entry(file: V_MEASUREMENT_FILE,
                                    iens: "#{measurement_ien.to_i},",
                                    fields: "2;.07;1201", flags: "IE")
      return [ nil, nil ] if reply.nil? || reply[:error]

      fields = reply[:fields]
      eie = internal(fields, "2") == "1"
      raw_date = internal(fields, "1201") || internal(fields, ".07")
      # 1201 may carry a time ("3260607.1430") or be date-only ("3260607").
      date = FilemanDateParser.parse_datetime(raw_date) || FilemanDateParser.parse_date(raw_date)
      [ eie, date ]
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
