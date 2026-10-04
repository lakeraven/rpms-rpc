# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/procedure"
require "rpms_rpc/api/ddr_fileman"

# Procedure.for_patient reads the patient's V CPT entries through BGOVCPT GET
# (GET^BGOVCPT, FOIA GUI Objects BGOVCPT.m:24-31 for the row layout), the read
# VueCentric's procedure component uses. It is in CIAV VUECENTRIC, the option
# sign-on binds, for PROV123 and the programmer alike.
#
# The spec asserts that the call answers for each demo patient, then checks
# one row against the V CPT entry it came from (file 9000010.18, read with
# DDR GETS ENTRY DATA). Which patient carries a V CPT is the build's seed, not
# the gem's contract, so the spec finds one with DDR LISTER rather than naming
# a DFN. The spec reads only; it files nothing.
class ProcedureLiveTest < LiveSpec::Test
  DEMO_DFNS = %w[3 990001 990027].freeze

  def test_for_patient_answers_for_each_demo_patient
    DEMO_DFNS.each do |dfn|
      rows = RpmsRpc::Procedure.for_patient(dfn)
      assert_kind_of Array, rows, "Procedure.for_patient(#{dfn}) answered #{rows.inspect}, not a list"
      rows.each { |row| assert_row_shape(row, dfn) }
    end
  end

  def test_a_v_cpt_row_matches_the_entry_it_came_from
    v_cpt_ien, dfn = first_v_cpt
    flunk "no V CPT on any patient: the pinned build ships one on DFN 4, visit 4; is this a fresh container of the pinned image?" if v_cpt_ien.nil?

    row = RpmsRpc::Procedure.for_patient(dfn).find { |r| r[:ien] == v_cpt_ien }
    refute_nil row, "V CPT #{v_cpt_ien} is on file for DFN #{dfn}, and Procedure.for_patient(#{dfn}) did not return it"
    assert_row_shape(row, dfn)

    entry = RpmsRpc::DdrFileman.gets_entry(file: "9000010.18", iens: "#{v_cpt_ien},", fields: ".01;.03;.16", flags: "IE")
    fields = entry.fetch(:fields)
    assert_equal fields.dig(".01", :external), row[:cpt_code], "CPT code disagrees with V CPT #{v_cpt_ien} field .01"
    assert_equal fields.dig(".03", :internal), row[:visit_ien], "visit disagrees with V CPT #{v_cpt_ien} field .03"
    quantity = fields.dig(".16", :internal)
    assert_equal (quantity.to_s.empty? ? nil : quantity.to_i), row[:quantity], "quantity disagrees with V CPT #{v_cpt_ien} field .16"
    puts "\n#{persona}: DFN #{dfn} V CPT #{v_cpt_ien} -> #{row.slice(:date, :cpt_code, :name, :provider).inspect}"
  end

  private

  def assert_row_shape(row, dfn)
    assert_match(/\A\d+\z/, row[:ien].to_s, "DFN #{dfn}: a row without a V CPT IEN: #{row.inspect}")
    assert_match(/\A\d+\z/, row[:visit_ien].to_s, "DFN #{dfn}: a row without a visit IEN: #{row.inspect}")
    assert_kind_of Date, row[:date], "DFN #{dfn}: the visit date did not parse: #{row.inspect}"
    refute_empty row[:cpt_code].to_s, "DFN #{dfn}: a row without a CPT code: #{row.inspect}"
    refute_empty row[:name].to_s, "DFN #{dfn}: a row without a narrative: #{row.inspect}"
  end

  # [V CPT IEN, patient DFN] of the first V CPT on file, or nil.
  def first_v_cpt
    listed = RpmsRpc::DdrFileman.lister(file: "9000010.18", fields: "@;.02", flags: "IP", max: "1")
    flunk "DDR LISTER on V CPT (9000010.18) gave no reply" if listed.nil?
    flunk "DDR LISTER on V CPT (9000010.18) answered an error" if listed[:error]

    entry = listed[:entries].first
    entry && [ entry[:ien], entry[:pieces].first ]
  end
end
