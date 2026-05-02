# frozen_string_literal: true

module RpmsRpc
  # Symbolic API for patient data. Engine code calls these methods
  # instead of referencing DataMapper mappings directly.
  module Patient
    extend self

    def find(dfn)
      return nil if dfn.nil? || dfn.to_i <= 0

      attrs = DataMapper.patient_select.fetch_one(dfn.to_s, extras: { dfn: dfn.to_i })
      return nil unless attrs

      extended = DataMapper.patient_id_info.fetch_one(dfn.to_s)
      attrs.merge!(extended) if extended

      attrs
    end

    def search(name_pattern)
      DataMapper.patient_list.fetch_many(name_pattern.to_s, "1")
    end

    def find_by_ssn(ssn)
      return nil if ssn.nil? || ssn.to_s.empty?

      DataMapper.patient_ssn.fetch_one(ssn.to_s)
    end
  end
end
