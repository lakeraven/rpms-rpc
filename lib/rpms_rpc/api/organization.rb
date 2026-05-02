# frozen_string_literal: true

module RpmsRpc
  module Organization
    extend self

    def find(ien)
      return nil if ien.nil?

      DataMapper.institution.fetch_one(ien.to_s)
    end
  end
end
