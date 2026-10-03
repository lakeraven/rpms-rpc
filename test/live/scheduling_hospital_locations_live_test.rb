# frozen_string_literal: true

require_relative "live_helper"
require "date"
require "rpms_rpc/api/scheduling"
require "rpms_rpc/api/ddr_fileman"

# BSDX HOSPITAL LOCATION (HOSPLOC^BSDX32) lists active clinics. Its two date
# columns come from $$GET1^DIQ with no "I" flag (BSDX32.m:35-36), so they are
# EXTERNAL dates (#221). No clinic on the pinned build has them set, so the
# spec sets them: it files an inactivate and a reactivate date on one clinic
# (file #44, fields 2505/2506) with DDR FILER, reads the list back, and puts
# the clinic back as it was.
#
# Contexts: BSDX HOSPITAL LOCATION is in BSDXRPC, the scheduling package's
# broker option, not in CIAV VUECENTRIC, so the read binds BSDXRPC (a
# least-privilege user is refused it under CIAV VUECENTRIC). DDR FILER is in
# CIAV VUECENTRIC, the option sign-on binds.
class SchedulingHospitalLocationsLiveTest < LiveSpec::Test
  writes!

  CLINIC_FILE = 44
  INACTIVATE = 2505
  REACTIVATE = 2506
  INACTIVATED_ON = Date.new(2025, 1, 15)
  REACTIVATED_ON = Date.new(2025, 3, 1)

  def test_rows_are_clinics_and_their_inactivate_and_reactivate_dates_parse
    clinic = clinic_rows.find { |r| r[:inactivate_date].nil? && r[:reactivate_date].nil? }
    refute_nil clinic, "no clinic without dates to edit"
    ien = clinic[:location_ien]
    @restore = original_dates(ien)

    file_dates(ien, INACTIVATE => fm(INACTIVATED_ON), REACTIVATE => fm(REACTIVATED_ON))

    edited = clinic_rows.find { |r| r[:location_ien] == ien }
    refute_nil edited, "clinic #{ien} has a reactivate date, so it is still listed"
    assert_equal INACTIVATED_ON, edited[:inactivate_date]
    assert_equal REACTIVATED_ON, edited[:reactivate_date]
  end

  def teardown
    file_dates(@restore[:ien], @restore[:values]) if @restore && client
  ensure
    super
  end

  private

  # Every row is a clinic (never the typed header), and every date that is
  # set is a Date.
  def clinic_rows
    rows = client.with_context("BSDXRPC") { RpmsRpc::Scheduling.hospital_locations }
    refute_empty rows
    rows.each do |r|
      refute_match(/\A[ITDF]\d{5}/, r[:location].to_s, "the typed header came back as a row")
      assert_operator r[:location_ien], :>, 0, "row #{r.inspect}"
      [ :inactivate_date, :reactivate_date ].each do |k|
        assert(r[k].nil? || r[k].is_a?(Date), "#{k} of #{r[:location]} is #{r[k].inspect}")
      end
    end
    rows
  end

  def original_dates(ien)
    got = RpmsRpc::DdrFileman.gets_entry(file: CLINIC_FILE, iens: "#{ien},", fields: "#{INACTIVATE};#{REACTIVATE}", flags: "I")
    values = [ INACTIVATE, REACTIVATE ].to_h do |f|
      v = got.dig(:fields, f.to_s, :internal).to_s
      [ f, v.empty? ? "@" : v ]
    end
    { ien: ien, values: values }
  end

  # FILE^DIE through DDR FILER: values are internal; "@" deletes.
  def file_dates(ien, values)
    rows = values.map { |field, value| { file: CLINIC_FILE, field: field, iens: "#{ien},", value: value } }
    result = RpmsRpc::DdrFileman.filer(mode: "EDIT", rows: rows)
    assert result && result[:success], "DDR FILER on clinic #{ien}: #{result.inspect}"
  end

  def fm(date) = RpmsRpc::FilemanDateParser.format_date(date)
end
