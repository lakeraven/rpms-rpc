# frozen_string_literal: true

module RpmsRpc
  module Location
    extend self

    def find(ien)
      return nil if ien.nil?

      DataMapper.hospital_location.fetch_one(ien.to_s)
    end
  end
end
