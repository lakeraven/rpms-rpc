# frozen_string_literal: true

require_relative "../mappings"

module RpmsRpc
  # Symbolic API for referral records. Read via referral_search /
  # referral_detail; write via BGOREF SET.
  module Referral
    extend self

    # Wire field order for BGOREF SET. Field positions are best-effort
    # pending wider trace capture; this list locks the order so a caller's
    # Hash key insertion order can't reshuffle the payload mid-flight.
    CREATE_FIELDS = %i[provider_ien specialty reason priority requested_date].freeze

    def for_patient(dfn)
      DataMapper.referral_search.fetch_many(dfn.to_s)
    end

    def find(ien)
      return nil if ien.nil?

      DataMapper.referral_detail.fetch_one(ien.to_s)
    end

    def delete(ien, reason: nil)
      DataMapper.referral_delete.fetch_one(ien.to_s, reason)
    end

    def create(dfn, params)
      raise ArgumentError, "params must be a Hash" unless params.is_a?(Hash)
      return failure if invalid_id?(dfn)

      payload = CREATE_FIELDS.map { |k| params[k].to_s }.join("^")
      raw = DataMapper.referral_create.fetch_scalar(dfn.to_s, payload)

      saved_ien = raw.to_s.match(/\A\d+/)&.to_s&.to_i
      {
        success: !saved_ien.nil? && saved_ien.positive?,
        ien: saved_ien,
        raw: raw
      }
    end

    private

    def failure
      { success: false, ien: nil, raw: nil }
    end

    def invalid_id?(value)
      value.nil? || value.to_s.strip.empty? || value.to_i <= 0
    end
  end
end
