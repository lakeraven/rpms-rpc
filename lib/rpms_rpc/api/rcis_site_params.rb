# frozen_string_literal: true

module RpmsRpc
  # Symbolic API for RCIS site parameters.
  # Underlying RPC: BMCRPC GTSITPRM.
  module RcisSiteParams
    extend self

    FIELD_MAP = {
      "COMMTHRESH" => :committee_threshold,
      "NOTIFYHR"   => :notification_grace_period,
      "PRISYS"     => :priority_system,
      "FACILITY"   => :facility_name,
      "FACILCODE"  => :facility_code
    }.freeze

    def for_facility(facility_ien)
      return nil if blank?(facility_ien) || facility_ien.to_i <= 0

      rows = DataMapper.site_params.fetch_many(facility_ien.to_s)
      return nil if rows.empty?

      params = rows.each_with_object({}) do |row, result|
        key = normalize_key(row[:key])
        result[key] = parse_param_value(row[:key], row[:value]) unless key.nil?
      end

      params.empty? ? nil : params
    end

    private

    def normalize_key(raw_key)
      mapped = FIELD_MAP[raw_key.to_s]
      return mapped if mapped

      normalized = raw_key.to_s.downcase.gsub(/\s+/, "_").gsub(/[^a-z0-9_]/, "")
      normalized.empty? ? nil : normalized.to_sym
    end

    def parse_param_value(key, value)
      case key.to_s.upcase
      when "COMMTHRESH", "NOTIFYHR"
        value.to_i
      when "PRISYS"
        value == "I" ? "ihs_2024" : "traditional"
      else
        value
      end
    end

    def blank?(val)
      val.nil? || val.to_s.empty?
    end
  end
end
