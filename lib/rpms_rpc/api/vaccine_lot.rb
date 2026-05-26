# frozen_string_literal: true

require "date"

module RpmsRpc
  module VaccineLot
    extend self

    def for_facility(facility_ien = nil)
      params = facility_ien.nil? ? [] : [ facility_ien.to_s ]
      lots = DataMapper.vaccine_lot_list.fetch_many(*params)
      lots.map { |lot| normalize_lot(lot) }
    end

    def find(ien)
      lot = DataMapper.vaccine_lot_detail.fetch_one(ien.to_s)
      normalize_lot(lot) if lot
    end

    private

    def normalize_lot(lot)
      lot.merge(expiration_date: parse_lot_date(lot[:expiration_date]))
    end

    def parse_lot_date(date_str)
      value = date_str.to_s
      return nil if value.empty?

      Date.parse(value)
    rescue Date::Error
      nil
    end
  end
end
