# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/coverage"

# What the front desk records and reads back for billing (rpms-ux S-REG-03.1):
# a Medicaid number with its state and eligibility dates, Medicare with its
# part and end date, and a private policy, each filed through AG's own
# windows and read back the way AG's registration client reads them
# (Coverage.on_file). FileMan confirms every value landed where AG files it.
# When AG lists no billable private insurer, the spec seeds the synthetic
# "ZZ LIVE PRIVATE INSURER" on #9999999.18 via DDR FILER so that cycle can run.
#
# Runs as the registration persona (PROFILE,REG): every call is in AGGRPC.
class CoverageOnFileLiveTest < LiveSpec::Test
  writes!

  DFN = 990_049 # ZEPHYR,QUINN on the pinned build; unused by other live specs
  CMS_EXAMPLE_MBI = "1EG4TE5MK73"
  SYNTHETIC_PRIVATE_INSURER = "ZZ LIVE PRIVATE INSURER"

  def test_medicaid_medicare_and_private_insurance_are_filed_and_read_back
    year = Date.today.year
    starts = "01/01/#{year}"
    ends = "12/31/#{year + 1}"
    state = state_ien!("WASHINGTON")
    insurer = private_insurer!
    private_record_ien = nil

    medicaid = RpmsRpc::Coverage.add_medicaid(DFN, effective_on: starts, ends_on: ends, number: "ZZ4900001",
                                                   state_ien: state, coverage: nil, client: client)
    assert medicaid[:success], "Medicaid add refused: #{medicaid.inspect}"
    record = medicaid[:record_ien]
    assert_equal "ZZ4900001", fileman("9000004", "#{record},", ".03"), "Medicaid number (#9000004 .03)"
    assert_equal state, fileman("9000004", "#{record},", ".04", "I"), "Medicaid state (#9000004 .04)"
    row = "#{medicaid[:multiple_ien]},#{record},"
    assert_equal "#{year + 1}-12-31", fm_date(fileman("9000004.11", row, ".02", "I")), "Medicaid end date (.02)"

    medicare = RpmsRpc::Coverage.add_medicare(DFN, name: "ZEPHYR,QUINN", number: CMS_EXAMPLE_MBI,
                                                   effective_on: starts, ends_on: ends, part: "B", client: client)
    assert medicare[:success], "Medicare add refused: #{medicare.inspect}"
    assert_equal "B", fileman("9000003.11", "#{medicare[:mien]},#{DFN},", ".03", "I"), "Medicare part (.03)"

    policy = RpmsRpc::Coverage.add_private_insurance(DFN, insurer_ien: insurer, policy_holder: "ZEPHYR,QUINN",
                                                          member_number: "ZZM49", effective_on: starts,
                                                          ends_on: ends, client: client)
    assert policy[:success], "private insurance add refused: #{policy.inspect}"
    private_record_ien = policy[:record_ien]

    begin
      assert_equal "ZZM49", fileman("9000006.11", "#{private_record_ien},#{DFN},", "21"), "member number (21)"

      on_file = RpmsRpc::Coverage.on_file(DFN, client: client)
      refute_nil on_file, "Coverage.on_file gave no answer"

      mcd = on_file[:medicaid].find { |entry| entry[:record_ien] == record }
      refute_nil mcd, "Medicaid record #{record} not read back: #{on_file[:medicaid].inspect}"
      assert_equal [ "MEDICAID", "ZZ4900001", "WASHINGTON", true ], mcd.values_at(:payer, :number, :state, :active)
      assert_equal [ Date.new(year, 1, 1), Date.new(year + 1, 12, 31) ], mcd[:eligibility].first.values_at(:starts_on, :ends_on)

      mcr = on_file[:medicare].first
      assert_equal [ CMS_EXAMPLE_MBI, true, "PART B" ], [ mcr[:number], mcr[:active], mcr[:eligibility].first[:coverage] ]

      pvt = on_file[:private].find { |entry| entry[:record_ien] == private_record_ien }
      refute_nil pvt, "private policy not read back: #{on_file[:private].inspect}"
      assert_equal [ "ZZM49", true, Date.new(year, 1, 1), Date.new(year + 1, 12, 31) ],
                   pvt.values_at(:number, :active, :starts_on, :ends_on)

      deleted = RpmsRpc::Coverage.delete_private_insurance(DFN, record_ien: private_record_ien, client: client)
      assert deleted[:success], "private insurance delete refused: #{deleted.inspect}"
      again = RpmsRpc::Coverage.delete_private_insurance(DFN, record_ien: private_record_ien, client: client)
      refute again[:success], "repeat delete should not succeed: #{again.inspect}"
      assert_equal :already_absent, again[:error]
      refute private_policy_row_on_file?(private_record_ien),
             "FileMan still has #9000006.11 #{private_record_ien},#{DFN}, after delete"
      after = RpmsRpc::Coverage.on_file(DFN, client: client)
      refute_nil after
      refute after[:private].any? { |entry| entry[:record_ien].to_s == private_record_ien.to_s },
             "private policy still listed in on_file: #{after[:private].inspect}"
      private_record_ien = nil

      puts "\n#{persona}: coverage filed, read back, and private policy deleted on DFN #{DFN}"
    ensure
      cleanup_private_policy!(private_record_ien)
    end
  end

  def test_a_lapsed_medicaid_record_reads_back_inactive
    medicaid = RpmsRpc::Coverage.add_medicaid(DFN, effective_on: "01/01/2024", ends_on: "06/30/2025",
                                                   number: "ZZ49LAPSE", state_ien: state_ien!("WASHINGTON"),
                                                   coverage: nil, client: client)
    assert medicaid[:success], "Medicaid add refused: #{medicaid.inspect}"

    mcd = RpmsRpc::Coverage.on_file(DFN, client: client)[:medicaid].find { |e| e[:record_ien] == medicaid[:record_ien] }
    refute_nil mcd
    assert_equal false, mcd[:active], "AG reads an eligibility that ended 06/30/2025 as not in force"
  end

  private

  def fileman(file, iens, field, flags = "E")
    got = RpmsRpc::DdrFileman.gets_entry(file: file, iens: iens, fields: field, flags: flags)
    flunk "FileMan read #{file} #{iens} #{field} failed: #{got.inspect}" if got.nil? || got[:error]
    got.dig(:fields, field, flags == "I" ? :internal : :external).to_s
  end

  # FileMan internal date (CYYMMDD) as ISO.
  def fm_date(value)
    text = value.to_s
    "#{text[0, 3].to_i + 1700}-#{text[3, 2]}-#{text[5, 2]}"
  end

  def state_ien!(name)
    got = RpmsRpc::DdrFileman.lister(file: "5", fields: "@;.01", flags: "IP", xref: "B", from: name[0..-2], part: name, max: "1")
    ien = Array(got && got[:entries]).first&.dig(:ien).to_s
    flunk "no STATE #{name} on this build: #{got.inspect}" if ien.empty?
    ien
  end

  # Billable PRIVATE insurer for AG's pick list; seeds SYNTHETIC_PRIVATE_INSURER
  # when the build has none (reuses an existing entry on re-run).
  def private_insurer!
    insurers = RpmsRpc::Coverage.insurers(client: client)
    flunk "AGG GET INSURANCE DATA gave no answer" if insurers.nil?
    found = insurers.find { |row| row[:type] == "PRIVATE" && row[:status] == "BILLABLE" }
    return found[:ien] if found

    flunk "#{persona} cannot bind CIAV VUECENTRIC for DDR FILER" unless client.create_context("CIAV VUECENTRIC")
    rows = { ".01" => SYNTHETIC_PRIVATE_INSURER, ".21" => "P", ".211" => "5", ".17" => "1" }.map do |field, value|
      { file: "9999999.18", field: field, iens: "+1,", value: value }
    end
    filed = RpmsRpc::DdrFileman.filer(mode: "ADD", rows: rows)
    flunk "DDR FILER could not seed synthetic private insurer: #{filed.inspect}" unless filed && filed[:success]

    insurers = RpmsRpc::Coverage.insurers(client: client)
    flunk "AGG GET INSURANCE DATA gave no answer after seeding insurer" if insurers.nil?
    found = insurers.find { |row| row[:type] == "PRIVATE" && row[:status] == "BILLABLE" }
    flunk "synthetic private insurer not listed after DDR FILER: #{insurers.map { |r| r[:name] }.inspect}" unless found
    found[:ien]
  end

  def private_policy_row_on_file?(record_ien)
    listed = RpmsRpc::DdrFileman.lister(file: "9000006.11", iens: ",#{DFN},", fields: "@;.01", flags: "IP", max: "*", xref: "#")
    flunk "FileMan list of 9000006.11 under #{DFN} gave no answer" if listed.nil?
    flunk "FileMan list of 9000006.11 under #{DFN} failed: #{listed.inspect}" if listed[:error]
    flunk "FileMan list of 9000006.11 under #{DFN} gave no data section: #{listed.inspect}" unless listed[:data] == true
    flunk "FileMan list of 9000006.11 under #{DFN} is incomplete (more rows): #{listed.inspect}" if listed[:more]

    Array(listed[:entries]).any? { |entry| entry[:ien].to_s == record_ien.to_s }
  end

  def cleanup_private_policy!(record_ien)
    return if record_ien.to_s.strip.empty?

    RpmsRpc::Coverage.delete_private_insurance(DFN, record_ien: record_ien, client: client)
  rescue StandardError
    # best-effort teardown when an earlier assertion failed
  end
end
