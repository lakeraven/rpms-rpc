# frozen_string_literal: true

require_relative "../shape"
require_relative "ddr_fileman"

module RpmsRpc
  # One HOSPITAL LOCATION (#44) by IEN, read with the registered generic
  # FileMan read DDR GETS ENTRY DATA (GETS^DIQ; GETSC^DDR2, DDR2.m:22-43), in
  # CIAV VUECENTRIC. The earlier BHDO HOSP LOC DATA name was registered
  # nowhere (#207).
  module Location
    extend self
    extend Shape::Declarable

    FILE = 44
    # .01 NAME, 1 ABBREVIATION, 2 TYPE (set: C CLINIC, W WARD, M MODULE, Z
    # OTHER LOCATION, N NON-CLINIC STOP, F FILE AREA, I IMAGING, OR
    # OPERATING ROOM), 3.5 DIVISION (pointer to MEDICAL CENTER DIVISION #40.8).
    SEARCH_MAX = 100
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
    shape :find, resource: "locations", verb: "GET", path: "/locations/{ien}"

    # Locations whose name starts with name, through LIST^DIC over the "B"
    # index (see DdrFileman.lister): [{ ien:, name: }], at most SEARCH_MAX, []
    # when none match, nil with no broker reply. #44 names are upper case.
    def search(name)
      listing = DdrFileman.lister(file: FILE, fields: FIELDS[:name], part: name.to_s.upcase, xref: "B", max: SEARCH_MAX)
      return nil if listing.nil?
      return [] if listing[:error]

      listing[:entries].map { |entry| { ien: entry[:ien].to_i, name: entry[:pieces]&.first } }
    end
    shape :search, resource: "locations", verb: "GET", path: "/locations"

    private

    def presence(value)
      value.to_s.empty? ? nil : value.to_s
    end
  end
end
