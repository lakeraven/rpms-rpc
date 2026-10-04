# frozen_string_literal: true

require_relative "../mappings"

module RpmsRpc
  # Symbolic API for VFC (Vaccines for Children) eligibility codes, read the
  # way VueCentric's immunization component reads them. Underlying RPCs, both
  # in CIAV VUECENTRIC: BGOVIMM2 GETELIG (the code table) and BGOVIMM GETVFC
  # (the patient's default). The earlier BIPC ELIGGET / ELIGLIST names were
  # registered nowhere (#207).
  #
  # Returns plain hashes: { code:, label: }. NIL_ELIGIBILITY for an invalid
  # DFN, or when the server's default names no eligibility code.
  module Eligibility
    extend self

    NIL_ELIGIBILITY = { code: nil, label: nil }.freeze

    # The patient's default VFC eligibility. BGOVIMM GETVFC answers a LABEL,
    # not a code: "Am Indian/AK Native" for beneficiary type 1 at an IHS
    # site, else a beneficiary-type IEN or nothing (GETVFC^BGOVIMM2,
    # BGOVIMM2.m:157-172). A label that matches a row of `codes` resolves to
    # that row; anything else is NIL_ELIGIBILITY, since the server named no
    # eligibility code.
    def for_patient(dfn)
      return NIL_ELIGIBILITY if dfn.nil? || !dfn.to_s.match?(/\A\d+\z/) || dfn.to_i <= 0

      label = DataMapper.vfc_default.fetch_one(dfn.to_s)&.dig(:default_label).to_s
      return NIL_ELIGIBILITY if label.empty?

      codes.find { |row| row[:label] == label } || NIL_ELIGIBILITY
    end

    # The server's active eligibility codes, [{ code:, label: }], from BI
    # TABLE ELIGIBILITY CODES (#9002084.83 .01 and .02) via BGOVIMM2 GETELIG.
    def codes
      Array(DataMapper.vfc_eligibility_codes.fetch_many("")).filter_map do |row|
        code = row[:code].to_s
        { code: code, label: row[:label].to_s } unless code.empty?
      end
    end
  end
end
