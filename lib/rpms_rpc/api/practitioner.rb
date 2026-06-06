# frozen_string_literal: true

module RpmsRpc
  module Practitioner
    extend self

    # ORWU USERINFO takes no params and returns the authenticated
    # session user's info, not an arbitrary IEN's. find(ien) succeeds
    # iff ien matches the session user's DUZ; for arbitrary-IEN lookup
    # see rr-fyf — no currently-mapped RPC supports that path.
    def find(ien)
      return nil if ien.nil? || ien.to_i <= 0

      result = DataMapper.practitioner_info.fetch_one
      return nil if result.nil? || result[:duz].to_i != ien.to_i

      result.merge(ien: result[:duz])
    end

    def search(name_pattern)
      DataMapper.practitioner_list.fetch_many(name_pattern.to_s, "1")
    end
  end
end
