# frozen_string_literal: true

module RpmsRpc
  module Device
    extend self

    def for_patient(dfn)
      return [] if blank?(dfn) || dfn.to_i <= 0
      return [] unless RpmsRpc.client.supports?(:orwpce_clinical_logs)

      DataMapper.device_list.fetch_many(dfn.to_s).map { |device| apply_defaults(device) }
    end

    def find(ien)
      return nil if blank?(ien) || ien.to_i <= 0
      return nil unless RpmsRpc.client.supports?(:orwpce_clinical_logs)

      device = DataMapper.device_detail.fetch_one(ien.to_s, extras: { ien: ien.to_s })
      apply_defaults(device) if device
    end

    private

    # Gateway behavior: `fields[3] || "active"`. Empty string is truthy in Ruby
    # and therefore retained as-is — we only default when status is nil or
    # absent.
    def apply_defaults(device)
      device.merge(status: device[:status] || "active")
    end

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end
  end
end
