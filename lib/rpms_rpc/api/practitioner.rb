# frozen_string_literal: true

module RpmsRpc
  module Practitioner
    extend self

    def find(ien)
      return nil if ien.nil? || ien.to_i <= 0

      DataMapper.practitioner_info.fetch_one(ien.to_s, extras: { ien: ien.to_i })
    end

    def search(name_pattern)
      DataMapper.practitioner_list.fetch_many(name_pattern.to_s, "1")
    end
  end
end
