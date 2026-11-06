# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/referral"
require "rpms_rpc/api/ddr_fileman"

# Referral.pending reads the referrals still open across every patient
# (rpms-rpc#589): BMC SEARCH REFERRAL with no patient and no provider, a date
# range and the routine's own "Active/Approved" status screen. With no
# patient, SRCHREF^BMCRPC1 walks the B index (DATE INITIATED) from the start
# date, keeps STATUS OF REFERRAL (.15) A or A1 inside the range, and stops at
# 100 entries (BMCRPC1.m:46-47), so the method reads page after page.
#
# It WRITES its fixtures, so it runs only against a disposable local
# container. A fresh container has no RCIS REFERRAL (#90001) on file. The
# RCIS writer (BMC ADD REFERRAL) takes 40 positional parameters a demo
# fixture cannot fill honestly, so the fixtures are filed with DDR FILER, the
# stock FileMan filer, as referral_cancel_live_test.rb does: date initiated,
# patient, in-house, outpatient and a status. Each fixture sits on its own
# date in a window no other spec files in (2001 and 2002), and a rerun files
# only the ones not already on file, so the answer for the window is known.
class ReferralPendingLiveTest < LiveSpec::Test
  writes!

  REFERRAL_FILE = "90001"

  # Two patients with an open referral (one ACTIVE, one APPROVED), a third
  # with one closed each way, and a pending one just past the window's end.
  WINDOW = (Date.new(2001, 1, 1)..Date.new(2001, 1, 31))
  FIXTURES = [
    { date: Date.new(2001, 1, 10), dfn: 990_002, status: "A" },
    { date: Date.new(2001, 1, 11), dfn: 990_003, status: "A1" },
    { date: Date.new(2001, 1, 12), dfn: 990_004, status: "C1" },
    { date: Date.new(2001, 1, 13), dfn: 990_004, status: "X" },
    { date: Date.new(2001, 2, 1), dfn: 990_002, status: "A" }
  ].freeze
  STATUS_NAMES = { "A" => "ACTIVE", "A1" => "APPROVED" }.freeze

  # More pending referrals than one BMC SEARCH REFERRAL call returns (100),
  # one per day from 2002-01-01.
  PAGED_DFN = 990_005
  PAGED_COUNT = 101
  PAGED_DATES = (0...PAGED_COUNT).map { |i| Date.new(2002, 1, 1) + i }.freeze
  # As many again on a single date.
  CROWDED_DATE = Date.new(2003, 1, 1)

  def test_pending_reads_the_open_referrals_of_every_patient_in_the_window
    iens = ensure_filed(FIXTURES)
    pending = FIXTURES.each_index.select { |i| WINDOW.cover?(FIXTURES[i][:date]) && STATUS_NAMES.key?(FIXTURES[i][:status]) }

    rows = RpmsRpc::Referral.pending(from: WINDOW.begin, to: WINDOW.end)

    assert_equal pending.map { |i| iens[i] }.sort, rows.map { |r| r[:ien] }.sort,
      "pending(#{WINDOW}) should be exactly the ACTIVE and APPROVED referrals initiated in it"
    pending.each do |i|
      fixture = FIXTURES[i]
      row = rows.find { |r| r[:ien] == iens[i] }
      assert_equal fixture[:dfn], row[:patient_dfn], "referral #{iens[i]}: patient"
      refute_empty row[:patient_name].to_s, "referral #{iens[i]}: patient name"
      assert_equal fixture[:date], row[:date], "referral #{iens[i]}: date initiated"
      assert_equal STATUS_NAMES.fetch(fixture[:status]), row[:status], "referral #{iens[i]}: status"
    end
    assert_equal 2, rows.map { |r| r[:patient_dfn] }.uniq.size, "two patients hold the pending referrals"
    puts "\n#{persona}: Referral.pending(#{WINDOW}) answered #{rows.size} of #{FIXTURES.size} fixture referrals: " \
         "#{rows.map { |r| "#{r[:ien]} #{r[:patient_dfn]} #{r[:status]}" }.join(', ')}"
  end

  def test_pending_reads_past_the_hundred_entries_one_call_returns
    fixtures = PAGED_DATES.map { |date| { date: date, dfn: PAGED_DFN, status: "A" } }
    iens = ensure_filed(fixtures)

    rows = RpmsRpc::Referral.pending(from: PAGED_DATES.first, to: PAGED_DATES.last)

    assert_equal PAGED_COUNT, rows.size, "pending should read all #{PAGED_COUNT} referrals, not the first page"
    assert_equal iens.sort, rows.map { |r| r[:ien] }.sort, "each referral once, and only the fixtures"
    puts "\n#{persona}: Referral.pending(#{PAGED_DATES.first}..#{PAGED_DATES.last}) answered #{rows.size} referrals"
  end

  # A page is resumed from the last date it reached, so more than 100 on one
  # date cannot be read past; the method says so instead of answering short.
  def test_pending_refuses_a_single_date_with_more_than_a_page
    filed = referrals_on_file.count { |key, _| key == [ fm(CROWDED_DATE), PAGED_DFN.to_s, "A" ] }
    (PAGED_COUNT - filed).times { file_referral(date: CROWDED_DATE, dfn: PAGED_DFN, status: "A") }

    error = assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Referral.pending(from: CROWDED_DATE, to: CROWDED_DATE) }
    assert_match(/more than 100 pending referrals initiated on JAN 01, 2003/, error.message)
  end

  # The broker sends CRTMSG's record nodes with nothing between them, so two
  # referrals arrive in one line; each must still be its own row.
  def test_for_patient_reads_every_referral_of_a_patient_with_several
    iens = ensure_filed(FIXTURES)
    dfn = FIXTURES.first[:dfn]
    expected = FIXTURES.each_index.select { |i| FIXTURES[i][:dfn] == dfn }.map { |i| iens[i] }

    rows = RpmsRpc::Referral.for_patient(dfn)

    assert_equal expected.sort, rows.map { |r| r[:ien] }.sort, "for_patient(#{dfn}) should answer each of its referrals"
  end

  def test_pending_with_the_window_reversed_is_refused_before_the_wire
    assert_raises(ArgumentError) { RpmsRpc::Referral.pending(from: WINDOW.end, to: WINDOW.begin) }
    assert_raises(ArgumentError) { RpmsRpc::Referral.pending(from: "2001-01-01", to: WINDOW.end) }
  end

  private

  # The IEN of each fixture, filing the ones not already on file.
  def ensure_filed(fixtures)
    on_file = referrals_on_file.to_h
    fixtures.map do |f|
      on_file[[ fm(f[:date]), f[:dfn].to_s, f[:status] ]] || file_referral(f)
    end
  end

  # [[date, dfn, status], ien] for every referral, internal values.
  def referrals_on_file
    listed = RpmsRpc::DdrFileman.lister(file: REFERRAL_FILE, fields: "@;.01;.03;.15", flags: "IP", max: "*")
    flunk "DDR LISTER on file #{REFERRAL_FILE} gave no reply" if listed.nil?
    flunk "DDR LISTER on file #{REFERRAL_FILE} answered an error" if listed[:error]

    listed[:entries].map { |e| [ e[:pieces].first(3), e[:ien] ] }
  end

  def file_referral(fixture)
    values = { ".01" => fm(fixture[:date]), ".03" => fixture[:dfn].to_s, ".04" => "N", ".14" => "O", ".15" => fixture[:status] }
    rows = values.map { |field, value| { file: REFERRAL_FILE, field: field, iens: "+1,", value: value } }
    filed = RpmsRpc::DdrFileman.filer(mode: "ADD", rows: rows)
    assert filed && filed[:success], "DDR FILER could not file fixture referral #{fixture}: #{filed.inspect}"
    filed[:iens].fetch(1)
  end

  def fm(date)
    format("%<y>03d%<m>02d%<d>02d", y: date.year - 1700, m: date.month, d: date.day)
  end
end
