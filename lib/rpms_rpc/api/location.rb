# frozen_string_literal: true

require_relative "ddr_fileman"

module RpmsRpc
  # One HOSPITAL LOCATION (#44) by IEN, read with the registered generic
  # FileMan read DDR GETS ENTRY DATA (GETS^DIQ; GETSC^DDR2, DDR2.m:22-43), in
  # CIAV VUECENTRIC. The earlier BHDO HOSP LOC DATA name was registered
  # nowhere (#207).
  module Location
    extend self

    FILE = 44
    # .01 NAME, 1 ABBREVIATION, 2 TYPE (set: C CLINIC, W WARD, M MODULE, Z
    # OTHER LOCATION, N NON-CLINIC STOP, F FILE AREA, I IMAGING, OR
    # OPERATING ROOM), 3.5 DIVISION (pointer to MEDICAL CENTER DIVISION #40.8).
    FIELDS = { name: ".01", abbreviation: "1", type: "2", division: "3.5" }.freeze

    # { ien:, name:, abbreviation:, type:, division: }, or nil for an
    # invalid or unknown IEN (DDR answers "[ERROR]") or no broker reply.
    # type and division are the external forms ("CLINIC", the division's
    # name); an empty field is nil.
    def find(ien)
      return nil unless ien.to_s.match?(/\A\d+\z/) && ien.to_i.positive?

      got = DdrFileman.gets_entry(file: FILE, iens: "#{ien.to_i},", fields: FIELDS.values.join(";"), flags: "IE")
      return nil if got.nil? || got[:error]

      values = FIELDS.transform_values { |field| presence(got[:fields].dig(field, :external)) }
      return nil if values[:name].nil?

      { ien: ien.to_i, **values }
    end

    private

    def presence(value)
      value.to_s.empty? ? nil : value.to_s
    end
  end
end
