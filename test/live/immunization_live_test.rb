# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/immunization"
require "rpms_rpc/api/ddr_fileman"

# Immunization.for_patient reads the patient's V IMMUNIZATION history through
# BGOVIMM GET (GET^BGOVIMM -> GET^BGOVIMM5, FOIA GUI Objects BGOVIMM5.m:206-275),
# the read VueCentric's immunization component uses; Immunization.find filters
# that read on the V IMMUNIZATION IEN. Both are in CIAV VUECENTRIC, the option
# sign-on binds, for PROV123 and the programmer alike.
#
# The spec asserts that the call answers for each demo patient, then checks
# one row against the V IMMUNIZATION entry it came from (file 9000010.11, read
# with DDR GETS ENTRY DATA). Which patient carries one is the build's seed, not
# the gem's contract, so the spec finds one with DDR LISTER rather than naming
# a DFN. The spec reads only; it files nothing.
class ImmunizationLiveTest < LiveSpec::Test
  DEMO_DFNS = %w[3 990001 990027].freeze

  # The keys the removed BIPC read returned. A host builds its model from
  # these, so the rebuilt read returns no key outside them.
  KEYS = %i[
    ien vaccine_code vaccine_display status lot_number expiration_date site route
    performer_duz performer_name occurrence_datetime dose_quantity dose_unit
    manufacturer vfc_eligibility_code funding_source
  ].freeze

  def test_for_patient_answers_for_each_demo_patient
    DEMO_DFNS.each do |dfn|
      rows = RpmsRpc::Immunization.for_patient(dfn)
      assert_kind_of Array, rows, "Immunization.for_patient(#{dfn}) answered #{rows.inspect}, not a list"
      rows.each { |row| assert_row_shape(row, dfn) }
    end
  end

  def test_a_v_immunization_row_matches_the_entry_it_came_from
    v_imm_ien, dfn = first_v_immunization
    skip_tracked("#373", "no V IMMUNIZATION on any demo patient (rpms-ops#721)") if v_imm_ien.nil?

    row = RpmsRpc::Immunization.for_patient(dfn).find { |r| r[:ien] == v_imm_ien }
    refute_nil row, "V IMMUNIZATION #{v_imm_ien} is on file for DFN #{dfn}, and Immunization.for_patient(#{dfn}) did not return it"
    assert_row_shape(row, dfn)

    fields = RpmsRpc::DdrFileman.gets_entry(file: "9000010.11", iens: "#{v_imm_ien},", fields: ".01;1201;1204", flags: "IE").fetch(:fields)
    assert_equal fields.dig(".01", :external), row[:vaccine_display], "vaccine disagrees with V IMMUNIZATION #{v_imm_ien} field .01"
    assert_equal blank_to_nil(fields.dig("1204", :internal)), row[:performer_duz], "provider disagrees with field 1204"
    event = blank_to_nil(fields.dig("1201", :internal))
    assert_equal event && RpmsRpc::FilemanDateParser.parse_datetime_or_date(event), row[:occurrence_datetime],
                 "event date disagrees with field 1201"
    puts "\n#{persona}: DFN #{dfn} V IMMUNIZATION #{v_imm_ien} -> #{row.slice(:vaccine_display, :occurrence_datetime, :performer_name).inspect}"
  end

  def test_find_returns_the_row_for_patient_returns
    v_imm_ien, dfn = first_v_immunization
    skip_tracked("#373", "no V IMMUNIZATION on any demo patient (rpms-ops#721)") if v_imm_ien.nil?

    expected = RpmsRpc::Immunization.for_patient(dfn).find { |r| r[:ien] == v_imm_ien }
    assert_equal expected, RpmsRpc::Immunization.find(v_imm_ien)
  end

  def test_find_answers_nil_for_an_ien_not_on_file
    assert_nil RpmsRpc::Immunization.find("999999999")
  end

  private

  def assert_row_shape(row, dfn)
    assert_empty row.keys - KEYS, "DFN #{dfn}: keys the removed read never returned: #{row.keys - KEYS}"
    assert_match(/\A\d+\z/, row[:ien].to_s, "DFN #{dfn}: a row without a V IMMUNIZATION IEN: #{row.inspect}")
    refute_empty row[:vaccine_display].to_s, "DFN #{dfn}: a row without a vaccine: #{row.inspect}"
  end

  def blank_to_nil(value) = value.to_s.empty? ? nil : value

  # [V IMMUNIZATION IEN, patient DFN] of the first one on file, or nil.
  def first_v_immunization
    listed = RpmsRpc::DdrFileman.lister(file: "9000010.11", fields: "@;.02", flags: "IP", max: "1")
    flunk "DDR LISTER on V IMMUNIZATION (9000010.11) gave no reply" if listed.nil?
    flunk "DDR LISTER on V IMMUNIZATION (9000010.11) answered an error" if listed[:error]

    entry = listed[:entries].first
    entry && [ entry[:ien], entry[:pieces].first ]
  end
end
