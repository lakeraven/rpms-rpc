# frozen_string_literal: true

require "bigdecimal"
require "date"

module RpmsRpc
  # Symbolic API for CHS vendor/provider lookup.
  # Underlying RPCs (BMCRPC family): SRCHVEND, GTVEND, GTPREFVEND,
  # GTCONTRACT, GTRATES.
  module Vendor
    extend self

    VENDOR_TYPES = %w[FACILITY INDIVIDUAL GROUP].freeze
    DETAIL_RAW_KEYS = %i[
      specialties_raw
      phone
      fax
      email
      contact_name
      street
      city
      state
      zip
      contracted_services_raw
    ].freeze

    def search(name: nil, specialty: nil, type: nil)
      rows = DataMapper.vendor_list.fetch_many(name.to_s, specialty.to_s, type.to_s)
      Array(rows).select do |row|
        matches_name?(row, name) && matches_specialty?(row, specialty) && matches_type?(row, type)
      end
    end

    def find(ien)
      return nil if invalid_ien?(ien)

      row = DataMapper.vendor_detail.fetch_one(ien.to_s)
      return nil if row.nil?

      decorate_detail(row)
    end

    def preferred(specialty: nil)
      rows = DataMapper.preferred_vendor_list.fetch_many(specialty.to_s)
      Array(rows).select { |row| row[:preferred] && matches_specialty?(row, specialty) }
    end

    def for_service(service)
      return [] if blank?(service)

      rows = DataMapper.vendor_service_list.fetch_many(service.to_s)
      Array(rows).select { |row| matches_service?(row, service) }.map { |row| decorate_rate_vendor(row) }
    end

    def contracts(ien)
      return [] if invalid_ien?(ien)

      Array(DataMapper.vendor_contract_list.fetch_many(ien.to_s)).map { |row| decorate_contract(row) }
    end

    def active_contract(ien)
      contracts(ien).find { |contract| contract[:active] || contract[:status] == "ACTIVE" }
    end

    def rates(ien)
      return [] if invalid_ien?(ien)

      Array(DataMapper.vendor_rate_list.fetch_many(ien.to_s)).map { |row| decorate_rate(row) }
    end

    def active?(ien)
      contract = active_contract(ien)
      return false if contract.nil?

      end_date = contract[:end_date]
      end_date.nil? || end_date >= Date.today
    end

    private

    def decorate_detail(row)
      row.merge(
        specialties: parse_csv(row[:specialties_raw]),
        contact_info: {
          phone: row[:phone],
          fax: row[:fax],
          email: row[:email],
          contact_name: row[:contact_name]
        },
        address: {
          street: row[:street],
          city: row[:city],
          state: row[:state],
          zip: row[:zip]
        },
        contracted_services: parse_csv(row[:contracted_services_raw])
      ).tap do |detail|
        DETAIL_RAW_KEYS.each { |key| detail.delete(key) }
      end
    end

    def decorate_rate_vendor(row)
      row.merge(
        rate: parse_decimal(row[:rate]),
        contracted_rate: parse_decimal(row[:rate])
      )
    end

    def decorate_contract(row)
      active = row[:end_date].nil? || row[:end_date] >= Date.today
      row.merge(
        status: active ? "ACTIVE" : "EXPIRED",
        active: active,
        services: parse_csv(row[:services_raw])
      ).tap { |contract| contract.delete(:services_raw) }
    end

    def decorate_rate(row)
      amount = parse_decimal(row[:rate])
      row.merge(
        service_type: row[:service],
        rate: amount,
        amount: amount
      )
    end

    def parse_csv(value)
      return [] if blank?(value)

      value.to_s.split(",").map(&:strip).reject(&:empty?)
    end

    def parse_decimal(value)
      return nil if blank?(value)

      BigDecimal(value.to_s)
    rescue ArgumentError
      nil
    end

    def matches_name?(row, name)
      return true if blank?(name)

      row[:name].to_s.downcase.include?(name.to_s.downcase)
    end

    def matches_specialty?(row, specialty)
      return true if blank?(specialty)

      needle = specialty.to_s.downcase
      specialty_text = row[:specialty].to_s.downcase
      specialties = row[:specialties] || parse_csv(row[:specialties_raw])
      specialty_text.include?(needle) ||
        specialties.any? { |entry| entry.to_s.downcase.include?(needle) }
    end

    def matches_type?(row, type)
      blank?(type) || row[:type] == type
    end

    def matches_service?(row, service)
      needle = service.to_s.downcase
      row[:service].to_s.downcase.include?(needle) || row[:specialty].to_s.downcase.include?(needle)
    end

    def invalid_ien?(ien)
      blank?(ien) || ien.to_i <= 0
    end

    def blank?(val)
      val.nil? || val.to_s.empty?
    end
  end
end
