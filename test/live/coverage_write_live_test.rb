# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/coverage"

# Live write/read/delete for Medicare and Medicaid coverage on a synthetic patient
# reserved for this spec (rpms-rpc#382). Private insurance is out of scope.
#
# Contract (panel round 2): row-scoped deletes; delete_medicare_record after the
# eligibility row is gone; Medicaid delete is one row (server drops empty records);
# CMS example MBI 1EG4TE5MK73; FileMan subfile IENS are child-first (mien,dfn,);
# assert row present before each delete, then gone after.
class CoverageWriteLiveTest < LiveSpec::Test
  writes!

  DFN = 990_048 # WILLOW,FINLEY on the pinned build; unused by other live specs
  MEDICARE_FILE = "9000003"
  MEDICARE_ELIG_FILE = "9000003.11"
  MEDICAID_FILE = "9000004"
  CMS_EXAMPLE_MBI = "1EG4TE5MK73"
  MEDICAID_NUMBER = "ZZ382MCD"

  def test_medicare_and_medicaid_coverage_round_trip
    today = Date.today.strftime("%m/%d/%Y")
    mcd_cov = "FULL"
    mcr = nil
    mcd = nil

    begin
      mcr = RpmsRpc::Coverage.add_medicare(DFN,
                                           roi_on: today,
                                           name: "ZZCOV382,MC",
                                           number: CMS_EXAMPLE_MBI,
                                           suffix: "A",
                                           effective_on: today)
      assert mcr[:success], "Medicare add failed: #{mcr.inspect}"
      assert_equal DFN, mcr[:rien]
      refute_empty mcr[:mien].to_s

      entries = coverage_entries!
      assert entries.any? { |row| row[:coverage].to_s.match?(/MEDICARE/i) },
             "BQI read missing Medicare row: #{entries.inspect}"

      m3 = RpmsRpc::DdrFileman.gets_entry(file: MEDICARE_FILE, iens: "#{DFN},", fields: ".03;.04", flags: "IE")
      refute m3[:error], "no #9000003 for DFN #{DFN}"
      assert_equal CMS_EXAMPLE_MBI, m3.dig(:fields, ".03", :external), "Medicare number (#9000003 .03)"

      state = state_ien!("WASHINGTON")
      mcd = RpmsRpc::Coverage.add_medicaid(DFN, effective_on: today, number: MEDICAID_NUMBER, state_ien: state,
                                                coverage: mcd_cov)
      assert mcd[:success], "Medicaid add failed: #{mcd.inspect}"
      refute_empty mcd[:record_ien].to_s

      entries = coverage_entries!
      assert entries.any? { |row| row[:coverage].to_s.include?(mcd_cov) && row[:coverage].to_s.match?(/MEDICAID/i) },
             "BQI read missing Medicaid row: #{entries.inspect}"

      m4 = RpmsRpc::DdrFileman.gets_entry(file: MEDICAID_FILE, iens: "#{mcd[:record_ien]},", fields: ".01;.02;.03;.04", flags: "IE")
      refute m4[:error], "no #9000004 IEN #{mcd[:record_ien]}"
      assert_equal DFN.to_s, m4.dig(:fields, ".01", :internal), "#9000004 .01 points at patient"
      assert_equal [ MEDICAID_NUMBER, state ], [ m4.dig(:fields, ".03", :internal), m4.dig(:fields, ".04", :internal) ],
                   "Medicaid number and state (#9000004 .03, .04)"

      assert medicare_eligibility_row_exists?(mcr[:mien]),
             "Medicare eligibility IEN #{mcr[:mien]} missing on FileMan before row delete"

      del_mcr = RpmsRpc::Coverage.delete_medicare(DFN, eligibility_mien: mcr[:mien], client: client)
      assert del_mcr[:success], "Medicare eligibility delete failed: #{del_mcr.inspect}"
      refute medicare_eligibility_row_exists?(mcr[:mien]),
             "Medicare eligibility IEN #{mcr[:mien]} still on FileMan after row delete"
      assert medicare_header_exists?, "Medicare header should remain until delete_medicare_record"

      assert medicaid_eligibility_row_exists?(mcd[:record_ien], mcd[:multiple_ien]),
             "Medicaid eligibility IEN #{mcd[:multiple_ien]} missing before row delete"

      del_mcd = RpmsRpc::Coverage.delete_medicaid(DFN, record_ien: mcd[:record_ien],
                                                  eligibility_mien: mcd[:multiple_ien], client: client)
      assert del_mcd[:success], "Medicaid delete failed: #{del_mcd.inspect}"
      refute medicaid_record_exists?(mcd[:record_ien]),
             "#9000004 IEN #{mcd[:record_ien]} still on FileMan after row delete"
      mcd = nil

      del_hdr = RpmsRpc::Coverage.delete_medicare_record(DFN, client: client)
      assert del_hdr[:success], "Medicare header delete failed: #{del_hdr.inspect}"
      refute medicare_header_exists?, "Medicare header still on FileMan after delete_medicare_record"
      mcr = nil

      assert_empty coverage_entries!, "coverage still listed after full cleanup: #{coverage_entries!.inspect}"

      puts "\n#{persona}: Medicare/Medicaid coverage round-trip on DFN #{DFN}"
    ensure
      cleanup_coverage!(mcr, mcd)
    end
  end

  private

  # STATE (#5) IEN by name, as coverage_on_file_live_test.rb finds it.
  def state_ien!(name)
    got = RpmsRpc::DdrFileman.lister(file: "5", fields: "@;.01", flags: "IP", xref: "B", from: name[0..-2], part: name, max: "1")
    ien = Array(got && got[:entries]).first&.dig(:ien).to_s
    flunk "no STATE #{name} on this build: #{got.inspect}" if ien.empty?
    ien
  end

  def coverage_entries!
    got = RpmsRpc::Coverage.for_patient(DFN, client: client)
    flunk "Coverage.for_patient returned nil — implement #382 fail-closed reads" if got.nil?
    assert_equal Hash, got.class
    assert_equal Array, got[:entries].class
    got[:entries]
  end

  # Existence helpers never turn a failed read into "absent". A FileMan error
  # or a missing reply raises, unless a second, successful and complete
  # lookup proves the entry is not there.

  def medicare_eligibility_row_exists?(mien)
    row_listed?(MEDICARE_ELIG_FILE, ",#{DFN},", mien)
  end

  def medicaid_eligibility_row_exists?(record_ien, multiple_ien)
    row_listed?("9000004.11", ",#{record_ien},", multiple_ien)
  end

  def medicare_header_exists?
    top_level_entry_exists?(MEDICARE_FILE, DFN)
  end

  def medicaid_record_exists?(record_ien)
    top_level_entry_exists?(MEDICAID_FILE, record_ien)
  end

  # Complete LIST^DIC of a subfile: an error, nil, or a MORE continuation is
  # a failed verification, not an answer.
  def row_listed?(file, iens, ien)
    listed = RpmsRpc::DdrFileman.lister(file: file, iens: iens, fields: "@;.01", flags: "IP")
    flunk "lister for #{file} #{iens} returned no reply" if listed.nil?
    flunk "lister for #{file} #{iens} errored: #{listed.inspect}" if listed[:error]
    flunk "lister for #{file} #{iens} was not complete: #{listed.inspect}" if listed[:more]

    listed[:entries].any? { |row| row[:ien].to_s == ien.to_s }
  end

  # GETS first. A clean read answers presence. A FileMan error is not taken
  # as absence; it is confirmed by a successful LIST^DIC on the IEN index
  # starting just before the IEN: absent only when the first entry is not it.
  def top_level_entry_exists?(file, ien)
    got = RpmsRpc::DdrFileman.gets_entry(file: file, iens: "#{ien},", fields: ".01", flags: "I")
    flunk "gets_entry for #{file} #{ien} returned no reply" if got.nil?
    return got.dig(:fields, ".01", :internal).to_s != "" unless got[:error]

    listed = RpmsRpc::DdrFileman.lister(file: file, fields: "@;.01", flags: "IP", max: 1,
                                        from: (ien.to_i - 1).to_s, xref: "#")
    flunk "gets_entry for #{file} #{ien} errored and the confirming lookup failed: #{listed.inspect}" if listed.nil? || listed[:error]

    listed[:entries].first.to_h[:ien].to_s == ien.to_s
  end

  def cleanup_coverage!(mcr, mcd)
    begin
      if mcd && mcd[:success]
        RpmsRpc::Coverage.delete_medicaid(DFN, record_ien: mcd[:record_ien],
                                          eligibility_mien: mcd[:multiple_ien], client: client)
      end
    rescue StandardError
      # best-effort teardown
    end

    begin
      if mcr && mcr[:success] && mcr[:mien].to_s != ""
        RpmsRpc::Coverage.delete_medicare(DFN, eligibility_mien: mcr[:mien], client: client)
      end
    rescue StandardError
      # best-effort teardown
    end

    begin
      RpmsRpc::Coverage.delete_medicare_record(DFN, client: client)
    rescue StandardError
      # best-effort teardown
    end
  end
end
