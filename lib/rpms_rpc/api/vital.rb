# frozen_string_literal: true

module RpmsRpc
  module Vital
    extend self

    # List a patient's vitals.
    # Underlying RPC: ORQQVI VITALS
    def for_patient(dfn)
      DataMapper.vitals.fetch_many(dfn.to_s)
    end

    # Vital field metadata for a location — name, abbreviation, units, range,
    # required-flag, percentile RPC pointer. Drives the entry-grid UI.
    # Underlying RPC: BEHOVM TEMPLATE
    def template(location_ien)
      DataMapper.vital_template.fetch_many(location_ien.to_s) || []
    end

    # Pre-save validation of a set of measurements. Calls BEHOVM VALIDATE
    # per-field and returns aggregated field-level errors without persisting.
    #
    #   validate(dfn, [{abbreviation:, value:}, ...])
    #   => { valid: bool, errors: [{ index:, abbreviation:, value:, error_message: }, ...] }
    #
    # The dfn param is accepted (and forwarded to the RPC call) so future
    # per-patient range adjustment (e.g. pediatric vs adult) lands without
    # signature change. Today the underlying RPC validates only against the
    # field's static range.
    def validate(dfn, measurements)
      measurements = Array(measurements)
      errors = measurements.each_with_index.filter_map do |m, idx|
        abbrev = m[:abbreviation]
        value  = m[:value]
        validated = DataMapper.vital_validate.fetch_scalar("#{abbrev}|#{value}", dfn.to_s)
        next nil if valid_response?(validated, value)

        {
          index:         idx,
          abbreviation:  abbrev,
          value:         value,
          error_message: "Validation failed: server returned #{validated.inspect}"
        }
      end
      { valid: errors.empty?, errors: errors }
    end

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
    # response. Callers needing the IENs must follow up with
    # `Vital.for_patient(dfn)` and match by recorded_date + abbreviation.
    def add(dfn, visit_string, measurements, provider_duz:)
      # provider_duz is required regardless of measurement count — checking
      # before the empty-list early return so add(..., [], provider_duz: nil)
      # also fails fast on the contract violation.
      raise ArgumentError, "provider_duz is required (got nil)" if provider_duz.nil?

      measurements = coerce_measurements(measurements)
      return { success: false, measurement_count: 0, raw: "EMPTY", payload: [] } if measurements.empty?

      payload = build_save_payload(dfn, visit_string, measurements, provider_duz: provider_duz)
      raw = DataMapper.vital_save.fetch_scalar(dfn.to_s, payload)

      {
        success:           raw.to_s == "0",
        measurement_count: measurements.length,
        raw:               raw,
        payload:           payload
      }
    end

    # Build the BEHOVM SAVE second-param payload — an array of caret-delimited
    # lines: HDR (visit string), VST (date/patient), and one VIT+ per measurement.
    # Public for testability; callers should normally go through .add.
    # provider_duz is required (matches .add); raises ArgumentError when nil.
    def build_save_payload(dfn, visit_string, measurements, provider_duz:)
      raise ArgumentError, "provider_duz is required (got nil)" if provider_duz.nil?

      now = FilemanDateParser.format_datetime(Time.now, seconds: true)
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

    def valid_response?(validated, value)
      return false if validated.nil?
      return false if validated.to_s.upcase == "INVALID"
      validated.to_s == value.to_s
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
