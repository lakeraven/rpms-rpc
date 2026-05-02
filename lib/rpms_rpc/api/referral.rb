# frozen_string_literal: true

module RpmsRpc
  module Referral
    extend self

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
  end
end
