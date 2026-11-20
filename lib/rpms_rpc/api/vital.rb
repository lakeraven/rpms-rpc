# frozen_string_literal: true

require_relative "../shape"
require_relative "../server_clock"

module RpmsRpc
  module Vital
    extend self
    extend Shape::Declarable

    # The patient's MOST RECENT vital per type, optionally within a
    # FileMan date range — NOT full history. Underlying RPC: ORQQVI
    # VITALS, which the #8994 registry dispatches to FASTVIT^ORQQVI
    # (.broker_dumps_8994_20260607.txt:565) — newest-in-range per vital
    # type only (ORQQVI.m:64-91; per-type `Q:OK` at ORQQVI.m:104-105/
    # 170-171). Rows are MEASUREMENT_IEN^TYPE^VALUE^DATETIME^DISPLAY^
    # METRIC^QUALIFIERS (ORQQVI.m:66-67,113,179; see the :vitals mapping).
    # No units piece on this wire — use RpmsRpc::Measurement.for_visit /
    # .latest for the units + provenance read. FASTVIT emits no sentinel
    # row when the patient has no vitals (empty reply); rows without a
    # measurement IEN are dropped defensively anyway.
    #
    # `start_date`/`end_date` accept Time/Date or FileMan strings
    # (ORQQVI.m:74-78 — omitted means all time).
    def for_patient(dfn, start_date: nil, end_date: nil)
      return [] if invalid_id?(dfn)

      params = [ dfn.to_s, fileman(start_date), fileman(end_date) ]
      params.pop while params.last.empty? && params.length > 1
      DataMapper.vitals.fetch_many(*params).reject { |r| r[:measurement_ien].nil? }
    end
    shape :for_patient, resource: "vitals", verb: "GET", path: "/patients/{dfn}/vitals"

    # Vital field metadata for a visit — name, abbreviation, units, range,
    # required-flag, percentile RPC pointer. Drives the entry-grid UI.
    # Underlying RPC: BEHOVM TEMPLATE.
    #
    # Formals: TEMPLATE(DATA,DFN,VSTR,METRIC) (BEHOVM.m:57-63): a patient
    # and a visit string ("LOC;DT;CAT;VISIT" — Encounter.visit_string), not
    # a location IEN; the routine takes the location from +VSTR and
    # defaults the visit piece to -1 (BEHOVM.m:59-60). METRIC is read as
    # $G(METRIC,-1) and normalised to -1 / 0 / 1 (QUERY^BEHOVM:
    # BEHOVM.m:95): -1 each vital's own default units, 0 US, 1 metric.
    # A location-only frame died in M on VSTR (#259).
    #
    # The reply is what GRID^BEHOVM builds: node 0 is a count header
    # "<vitals>^<dates>^<results>" (BEHOVM.m:45), the vital rows follow
    # (node 0,n, merged from VLIST), then the visit's date and result rows
    # (GRIDX, BEHOVM.m:48-54). Only the <vitals> rows after the header are
    # template rows. Read whole, the header parsed as a vital whose IEN was
    # the count.
    def template(dfn, visit_string, metric: -1)
      return [] if invalid_id?(dfn) || visit_string.to_s.strip.empty?

      mapping = DataMapper.vital_template
      lines = mapping.fetch_text(dfn.to_s, visit_string.to_s, metric.to_i.to_s).to_s.split(/\r?\n/)
      count = lines.first.to_s.split("^").first.to_i
      mapping.parse_many(lines[1, count] || [])
    end
    shape :template, resource: "vitals", verb: "GET", path: "/patients/{dfn}/vitals/template"

    # The patient's latest measurement of each vital type on the site's
    # BEHOVM VITAL LIST, as VueCentric's vitals cover sheet lists them.
    # Underlying RPC: BEHOVM LIST (LIST^BEHOVM, BEHOVM.m:6, RMAX 1).
    #
    #   latest_by_type(dfn, start_date: nil, end_date: nil)
    #   => [{ measurement_ien:, name:, abbreviation:, taken_at:, value:, alternate_value:, qualifiers: }, ...]
    #
    # value is the reading with its units ("142/88 mmHg") in the vital's
    # default units, and alternate_value the same reading in the other
    # system when it differs (LISTX writes both, whatever METRIC says)
    # ("97.069 kg"); qualifiers as the routine joins them. measurement_ien is
    # the V MEASUREMENT (#9000010.01) IEN. The range defaults to all history
    # up to today (QUERY^BEHOVM). A -N^text reply raises Client::RpcError.
    def latest_by_type(dfn, start_date: nil, end_date: nil)
      return [] if invalid_id?(dfn)

      DataMapper.vital_latest_by_type.lines!(dfn.to_s, fileman(start_date), fileman(end_date), "", "", "", "", "").map do |line|
        ien, name, abbreviation, taken, value, alternate, qualifiers = line.split("^", -1)
        raise Client::RpcError, "BEHOVM LIST answered #{line.inspect}, not a vital row" unless ien.to_s.match?(/\A[1-9]\d*\z/)

        { measurement_ien: ien.to_i, name: name, abbreviation: abbreviation,
          taken_at: FilemanDateParser.parse_datetime_or_date(taken.to_s), value: value.to_s.strip,
          alternate_value: alternate.to_s.strip.empty? ? nil : alternate.strip,
          qualifiers: qualifiers.to_s.strip.empty? ? nil : qualifiers.strip }
      end
    end
    shape :latest_by_type, resource: "vitals", verb: "GET", path: "/patients/{dfn}/vitals/latest-by-type"

    # The patient's vitals over a range as VueCentric's vitals grid shows
    # them: the vital types (columns) and every measurement in range.
    # Underlying RPC: BEHOVM GRID (GRID^BEHOVM, BEHOVM.m:40).
    #
    #   grid(dfn, start_date: nil, end_date: nil, max_per_type: nil, metric: -1)
    #   => { vitals: [{ control_ien:, type_ien:, name:, abbreviation:, units:, low:, high:,
    #                   percentile_rpc:, has_qualifiers: }, ...],
    #        results: [{ abbreviation:, taken_at:, value:, flag:, measurement_ien:, qualifiers: }, ...] }
    #
    # GRID writes a count header VITALS^DATES^RESULTS, the vital rows
    # (VCTL^VTYP^NAME^ABBR^UNITS^LOW^HIGH^PCTILE RPC^HAS QUALIFIERS^SD), a
    # row per date (N^DATE), then the result rows (DATE N^VITAL N^VALUE^
    # FLAG^VIEN^QUALIFIERS). Each result is resolved to its vital's
    # abbreviation and its date. flag is :low or :high against the vital's
    # range (FLAG^BEHOVM), else nil. max_per_type caps the results per vital
    # (blank is the BEHOVM MAX RETURN parameter). A reply whose counts do
    # not match its rows raises Client::RpcError.
    def grid(dfn, start_date: nil, end_date: nil, max_per_type: nil, metric: -1)
      return { vitals: [], results: [] } if invalid_id?(dfn)

      lines = DataMapper.vital_grid.lines!(dfn.to_s, fileman(start_date), fileman(end_date), max_per_type.to_s,
                                           "", "", metric.to_i.to_s, "", "", "")
      return { vitals: [], results: [] } if lines.empty?

      read_grid(lines)
    end
    shape :grid, resource: "vitals", verb: "GET", path: "/patients/{dfn}/vitals/grid"

    # Pre-save validation of a set of measurements: BEHOVM VALIDATE for each
    # one, nothing filed.
    #
    #   validate(dfn, [{abbreviation:, value:}, ...], metric: -1)
    #   => { valid: bool, errors: [{ index:, abbreviation:, value:, error_message: }, ...] }
    #
    # Formals: VALIDATE(DATA,VCTL,METRIC,X) (BEHOVM.m:359): the vital type
    # (its abbreviation, resolved by TYPEINFO), the units flag (-1 the type's
    # own default units, 0 US, 1 metric, as for {template}) and the value.
    # The routine answers the value it would file, in the type's default
    # units ("36C" for TMP answers 96.8), or "-1^<why>" for a value it
    # refuses (BEHOVM.m:371): a filed value never holds a caret, so a reply
    # with one is a refusal (BEHOVM.m:372). error_message is the server's
    # reason.
    # A type the build does not have faults in the routine (LVUNDEF
    # VUNT("")); that measurement is an error, not a raise.
    #
    # dfn is accepted for callers and not sent: VALIDATE takes no patient
    # (#665). A frame of "<abbrev>|<value>" and the DFN left X undefined,
    # so every measurement died in M.
    def validate(dfn, measurements, metric: -1)
      errors = Array(measurements).each_with_index.filter_map do |m, idx|
        message = refusal(m[:abbreviation], m[:value], metric)
        next if message.nil?

        { index: idx, abbreviation: m[:abbreviation], value: m[:value], error_message: message }
      end
      { valid: errors.empty?, errors: errors }
    end
    shape :validate, resource: "vitals", verb: "POST", path: "/patients/{dfn}/vitals/validate"

    # Bulk-save a set of measurements against an open visit.
    #
    #   add(dfn, visit_string, [{abbreviation:, value:, units:}, ...], provider_duz:)
    #   => { success: bool, measurement_count: N, raw: <save_response>, payload: [...] }
    #
    # Builds the BEHOVM SAVE payload (HDR + VST + VIT+ lines, per observed
    # client behavior) and sends it as the second RPC param. The underlying
    # RPC returns "0" on success; non-"0"/non-empty responses are surfaced
    # as the raw result code in a failure result.
    #
    # Note: BEHOVM SAVE does not return saved-measurement IENs in its
    # response, and there is no reliable read-back for them.
    #
    # Do NOT recover them from `Vital.for_patient(dfn)`: that runs
    # "ORQQVI VITALS", which the #8994 registry dispatches to FASTVIT^ORQQVI
    # — at most ONE row per type, the newest in range. A backdated save, or
    # a second value of a type that already has a newer row, is simply not
    # in the reply, so a date+abbreviation match misses with no error and
    # the caller concludes the save failed. (The full-range read,
    # "ORQQVI VITALS FOR DATE RANGE", is GMRV #120.5 only — no IHS branch —
    # so its IENs are not V MEASUREMENT IENs either.)
    #
    # A caller that needs the IEN of a specific measurement should read the
    # visit instead: `RpmsRpc::Measurement.for_visit(visit_ien)` returns
    # every V MEASUREMENT on that visit with its IEN.
    #
    # taken_at is when the measurements were taken, as the site's wall-clock
    # Time (the caller's RPMS clock, not this process's); it is filed as each
    # measurement's date/time. Omitted, it is now on the server's clock
    # (ServerClock, ORWU DT "NOW"), not this process's (rpms-rpc#741).
    def add(dfn, visit_string, measurements, provider_duz:, taken_at: nil)
      # provider_duz is required regardless of measurement count — checking
      # before the empty-list early return so add(..., [], provider_duz: nil)
      # also fails fast on the contract violation.
      raise ArgumentError, "provider_duz is required (got nil)" if provider_duz.nil?

      measurements = coerce_measurements(measurements)
      return { success: false, measurement_count: 0, raw: "EMPTY", payload: [] } if measurements.empty?

      payload = build_save_payload(dfn, visit_string, measurements, provider_duz: provider_duz,
                                                                    taken_at: taken_at || ServerClock.now)
      raw = DataMapper.vital_save.fetch_scalar(dfn.to_s, payload)

      {
        success:           raw.to_s == "0",
        measurement_count: measurements.length,
        raw:               raw,
        payload:           payload
      }
    end
    shape :add, resource: "vitals", verb: "POST", path: "/patients/{dfn}/vitals"

    # Build the BEHOVM SAVE second-param payload — an array of caret-delimited
    # lines: HDR (visit string), VST (date/patient), and one VIT+ per measurement.
    # Public for testability; callers should normally go through .add.
    # provider_duz is required (matches .add); raises ArgumentError when nil.
    # taken_at is required here (.add supplies the server's now when its
    # caller gives none), so building a payload sends no RPC.
    def build_save_payload(dfn, visit_string, measurements, provider_duz:, taken_at:)
      raise ArgumentError, "provider_duz is required (got nil)" if provider_duz.nil?

      now = FilemanDateParser.format_datetime(taken_at, seconds: true)
      duz = provider_duz.to_s
      payload = [ "HDR^^^#{visit_string}" ]
      payload << "VST^DT^#{now}"
      payload << "VST^PT^#{dfn}"
      measurements.each do |m|
        units = m[:units].to_s
        payload << "VIT+^#{m[:abbreviation]}^0^^#{m[:value]}^#{duz}^#{units}^^#{now}^^"
      end
      payload
    end

    private

    GRID_FLAGS = { "L" => :low, "H" => :high }.freeze

    def read_grid(lines)
      vital_count, date_count, result_count = lines.first.split("^").map { |n| Integer(n, exception: false) }
      body = lines.drop(1)
      unless vital_count && date_count && result_count && body.size >= vital_count + date_count + result_count
        raise Client::RpcError, "BEHOVM GRID answered header #{lines.first.inspect} over #{body.size} rows"
      end

      vitals = body.first(vital_count).map { |line| grid_vital(line.split("^", -1)) }
      dates = body[vital_count, date_count].to_h do |line|
        n, date = line.split("^", 2)
        [ n.to_i, FilemanDateParser.parse_datetime_or_date(date.to_s) ]
      end
      results = body.last(result_count).map { |line| grid_result(line.split("^", -1), vitals, dates) }
      { vitals: vitals, results: results }
    end

    def grid_vital(pieces)
      control, type, name, abbreviation, units, low, high, percentile, qualifiers = pieces
      { control_ien: control.to_i, type_ien: type.to_i, name: name, abbreviation: abbreviation,
        units: units.to_s.empty? ? nil : units, low: low.to_s.empty? ? nil : low, high: high.to_s.empty? ? nil : high,
        percentile_rpc: percentile.to_s.empty? ? nil : percentile, has_qualifiers: qualifiers == "1" }
    end

    def grid_result(pieces, vitals, dates)
      date_n, vital_n, value, flag, vien, qualifiers = pieces
      vital = vitals[vital_n.to_i - 1]
      raise Client::RpcError, "BEHOVM GRID result #{pieces.join('^').inspect} names no listed vital or date" unless vital && dates.key?(date_n.to_i)

      { abbreviation: vital[:abbreviation], taken_at: dates[date_n.to_i], value: value.to_s.strip,
        flag: GRID_FLAGS[flag.to_s], measurement_ien: vien.to_i, qualifiers: qualifiers.to_s.empty? ? nil : qualifiers }
    end

    def invalid_id?(value)
      value.nil? || value.to_s.strip.empty? || value.to_i <= 0
    end

    # Coerce a Time/Date/FileMan-string range bound to the FileMan string
    # FASTVIT expects; nil → "" (server-side default, ORQQVI.m:74-78).
    def fileman(value)
      case value
      when nil then ""
      when Time then FilemanDateParser.format_datetime(value)
      when Date then FilemanDateParser.format_date(value)
      else value.to_s
      end
    end

    # Why BEHOVM VALIDATE refuses one measurement, or nil when it accepts it.
    def refusal(abbreviation, value, metric)
      reply = DataMapper.vital_validate.fetch_scalar(abbreviation.to_s, metric.to_i.to_s, value.to_s)
      return "No reply from BEHOVM VALIDATE" if reply.nil?
      return nil unless reply.include?("^")

      why = reply.split("^", 2)[1].to_s.strip
      why.empty? ? "Invalid entry." : why
    rescue Client::RpcMError
      "The server could not validate a #{abbreviation} measurement"
    end

    # Accepts an Array of measurement hashes OR a single measurement hash.
    # Ruby's Array() coerces a Hash into [[:k,:v],...] pairs which would
    # break payload construction — explicitly wrap single hashes instead.
    def coerce_measurements(measurements)
      return [] if measurements.nil?
      measurements.is_a?(Array) ? measurements : [ measurements ]
    end
  end
end

require_relative "vital_stock"
