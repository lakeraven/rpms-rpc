# frozen_string_literal: true

require_relative "ddr_fileman"

module RpmsRpc
  # One INSTITUTION (#4) by IEN, read with the registered generic FileMan
  # read DDR GETS ENTRY DATA (GETS^DIQ; GETSC^DDR2, DDR2.m:22-43), in CIAV
  # VUECENTRIC. The earlier BHDO INST DATA name was registered nowhere (#207).
  module Organization
    extend self

    FILE = 4
    # .01 NAME, 99 STATION NUMBER, 1.01 / 1.02 STREET ADDR. 1 / 2, 1.03 CITY,
    # .02 STATE (pointer to STATE #5), 1.04 ZIP.
    FIELDS = %w[.01 99 1.01 1.02 1.03 .02 1.04].freeze

    # { ien:, name:, station_number:, address:, city:, state:, zip_code:,
    # phone: }, or nil for an invalid or unknown IEN (DDR answers "[ERROR]")
    # or no broker reply. address joins street lines 1 and 2; state is the
    # external form (the state's name). phone is always nil: file #4 has no
    # phone field. An empty field is nil.
    def find(ien)
      return nil unless ien.to_s.match?(/\A\d+\z/) && ien.to_i.positive?

      got = DdrFileman.gets_entry(file: FILE, iens: "#{ien.to_i},", fields: FIELDS.join(";"), flags: "IE")
      return nil if got.nil? || got[:error]

      value = ->(field) { presence(got[:fields].dig(field, :external)) }
      return nil if value.(".01").nil?

      {
        ien: ien.to_i,
        name: value.(".01"),
        station_number: value.("99"),
        address: presence([ value.("1.01"), value.("1.02") ].compact.join(", ")),
        city: value.("1.03"),
        state: value.(".02"),
        zip_code: value.("1.04"),
        phone: nil
      }
    end

    private

    def presence(value)
      value.to_s.empty? ? nil : value.to_s
    end
  end
end
