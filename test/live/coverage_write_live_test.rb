# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/coverage"

# Live write/read/delete for Medicare and Medicaid coverage on a synthetic patient
# reserved for this spec (rpms-rpc#382). Private insurance is out of scope.
class CoverageWriteLiveTest < LiveSpec::Test
  writes!

  DFN = 990_048 # WILLOW,FINLEY on the pinned build; unused by other live specs
  MEDICARE_FILE = "9000003"
  MEDICAID_FILE = "9000004"

  def test_medicare_and_medicaid_coverage_round_trip
    today = Date.today.strftime("%m/%d/%Y")
    mcr_num = "1EG4TE5MK48"
    mcd_cov = "FULL"

    mcr = RpmsRpc::Coverage.add_medicare(DFN,
                                         roi_on: today,
                                         name: "ZZCOV382,MC",
                                         number: mcr_num,
                                         suffix: "A",
                                         effective_on: today)
    assert mcr[:success], "Medicare add failed: #{mcr.inspect}"
    assert_equal DFN, mcr[:rien]

    entries = coverage_entries!
    assert entries.any? { |row| row[:coverage].to_s.match?(/MEDICARE/i) && row[:effective_on].to_s.match?(/#{Date.today.strftime("%b").upcase}/) },
           "BQI read missing Medicare row: #{entries.inspect}"

    m3 = RpmsRpc::DdrFileman.gets_entry(file: MEDICARE_FILE, iens: "#{DFN},", fields: ".03;.04", flags: "IE")
    refute m3[:error], "no #9000003 for DFN #{DFN}"
    assert_equal mcr_num, m3.dig(:fields, ".03", :external), "Medicare number (#9000003 .03)"

    mcd = RpmsRpc::Coverage.add_medicaid(DFN, effective_on: today, coverage: mcd_cov)
    assert mcd[:success], "Medicaid add failed: #{mcd.inspect}"
    refute_empty mcd[:record_ien].to_s

    entries = coverage_entries!
    assert entries.any? { |row| row[:coverage].to_s.include?(mcd_cov) && row[:coverage].to_s.match?(/MEDICAID/i) },
           "BQI read missing Medicaid row: #{entries.inspect}"

    m4 = RpmsRpc::DdrFileman.gets_entry(file: MEDICAID_FILE, iens: "#{mcd[:record_ien]},", fields: ".01;.02", flags: "IE")
    refute m4[:error], "no #9000004 IEN #{mcd[:record_ien]}"
    assert_equal DFN.to_s, m4.dig(:fields, ".01", :internal), "#9000004 .01 points at patient"

    del_mcr = RpmsRpc::Coverage.delete_medicare(DFN, eligibility_mien: mcr[:mien], client: client)
    assert del_mcr[:success], "Medicare delete failed: #{del_mcr.inspect}"
    assert_empty coverage_entries!.select { |row| row[:coverage].to_s.match?(/MEDICARE/i) },
                 "Medicare still listed after delete: #{coverage_entries!.inspect}"

    del_mcd = RpmsRpc::Coverage.delete_medicaid(DFN, record_ien: mcd[:record_ien],
                                                eligibility_mien: mcd[:multiple_ien], client: client)
    assert del_mcd[:success], "Medicaid delete failed: #{del_mcd.inspect}"
    assert_empty coverage_entries!, "coverage still listed after Medicaid delete: #{coverage_entries!.inspect}"

    puts "\n#{persona}: Medicare/Medicaid coverage round-trip on DFN #{DFN}"
  end

  private

  def coverage_entries!
    got = RpmsRpc::Coverage.for_patient(DFN, client: client)
    flunk "Coverage.for_patient returned nil — implement #382" if got.nil?
    assert_equal Hash, got.class
    assert_equal Array, got[:entries].class
    got[:entries]
  end
end
