# frozen_string_literal: true

require_relative "../shape"
require_relative "../fileman_date_parser"
require_relative "ddr_fileman"

module RpmsRpc
  # Vaccine lots: IMMUNIZATION LOT (#9999999.41, ^AUTTIML), read with the
  # registered generic FileMan reads DDR GETS ENTRY DATA and DDR LISTER, in
  # CIAV VUECENTRIC.
  #
  # Neither registered lot RPC carries what a VFC check needs. BGOVIMM LOT
  # (LOT^BGOVIMM2) answers LOT^NAME^MANUFACTURER^EXPIRATION for one vaccine,
  # and BI LOT NUMBERS GET MATCHING (LOTNUMS^BIRPC2) answers IEN^LOT NUMBER;
  # the lot's VACCINE SOURCE (.13) is in neither. So both reads go to the file.
  module ImmunizationLot
    extend self
    extend Shape::Declarable

    FILE = "9999999.41"
    VACCINE_FILE = "9999999.14"
    # .01 LOT NUMBER, .03 STATUS (0 ACTIVE, 1 INACTIVE), .04 VACCINE (pointer
    # to IMMUNIZATION #9999999.14), .09 EXPIRATION DATE, .13 VACCINE SOURCE.
    FIELDS = %w[.01 .03 .04 .09 .13].freeze
    # VACCINE SOURCE's set of codes, as the field's DD declares them.
    SOURCES = {
      "v" => "VFC", "n" => "NON-VFC", "o" => "Other State", "i" => "IHS/Tribal", "VXC1" => "Federal fund"
    }.freeze

    # One lot by IEN:
    #   { ien:, lot_number:, active:, vaccine_ien:, vaccine:, cvx:,
    #     expiration_date:, source:, source_label: }
    # source is the VACCINE SOURCE internal code ("v" is VFC); cvx is the
    # vaccine's HL7-CVX CODE (#9999999.14 .03). nil for an invalid or unknown
    # IEN, or no broker reply.
    def find(ien)
      return nil unless ien.to_s.match?(/\A\d+\z/) && ien.to_i.positive?

      got = DdrFileman.gets_entry(file: FILE, iens: "#{ien.to_i},", fields: FIELDS.join(";"), flags: "IE")
      return nil if got.nil? || got[:error]

      field = ->(f, form) { presence(got[:fields].dig(f, form)) }
      return nil if field.(".01", :internal).nil?

      lot(ien.to_i,
        lot_number: field.(".01", :internal),
        status: field.(".03", :internal),
        vaccine_ien: field.(".04", :internal),
        expiration: field.(".09", :internal),
        source: field.(".13", :internal))
    end
    shape :find, resource: "immunization-lots", verb: "GET", path: "/immunization-lots/{ien}"

    # Every lot on file, active or not, in the same shape as find. [] when
    # the file holds none; nil when DDR LISTER answers nothing.
    def list
      listed = DdrFileman.lister(file: FILE, fields: ".01I;.03I;.04I;.09I;.13I", flags: "IP")
      return nil if listed.nil? || listed[:error]

      vaccines = {}
      listed[:entries].map do |entry|
        number, status, vaccine_ien, expiration, source = entry[:pieces].map { |p| presence(p) }
        lot(entry[:ien].to_i, lot_number: number, status: status, vaccine_ien: vaccine_ien,
          expiration: expiration, source: source, vaccines: vaccines)
      end
    end
    shape :list, resource: "immunization-lots", verb: "GET", path: "/immunization-lots"

    private

    def lot(ien, lot_number:, status:, vaccine_ien:, expiration:, source:, vaccines: {})
      vaccine = vaccine_ien && (vaccines[vaccine_ien] ||= vaccine(vaccine_ien))
      {
        ien: ien,
        lot_number: lot_number,
        active: status == "0",
        vaccine_ien: vaccine_ien&.to_i,
        vaccine: vaccine&.dig(:name),
        cvx: vaccine&.dig(:cvx),
        expiration_date: expiration && FilemanDateParser.parse_date(expiration),
        source: source,
        source_label: SOURCES[source]
      }
    end

    # The vaccine's NAME (.01) and HL7-CVX CODE (.03).
    def vaccine(ien)
      got = DdrFileman.gets_entry(file: VACCINE_FILE, iens: "#{ien.to_i},", fields: ".01;.03", flags: "I")
      return nil if got.nil? || got[:error]

      { name: presence(got[:fields].dig(".01", :internal)), cvx: presence(got[:fields].dig(".03", :internal)) }
    end

    def presence(value)
      value.to_s.empty? ? nil : value.to_s
    end
  end
end
