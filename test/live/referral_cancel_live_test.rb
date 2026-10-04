# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/referral"
require "rpms_rpc/api/ddr_fileman"

# Referral.cancel files STATUS OF REFERRAL (file 90001, field .15) as X
# (CLOSED-NOT COMPLETED, the code RCIS's reports skip as cancelled) through
# BMC REFERRAL STATUS UPDATE (UPDTSTRF^BMCRPC3, FOIA BMCRPC3.m:176-187), which
# is in the BMCRPC option.
#
# It WRITES, so it runs only against a disposable local container. It needs
# an active referral. The RCIS writer, BMC ADD REFERRAL (SETREFRL^BMCRPC2),
# cannot be called on a YottaDB build: it has 40 formals, the 35th (SNOMED
# preferred term) is required, and YottaDB takes at most 32 actual arguments
# (the broker answers %YDB-E-MAXACTARG). So the spec reuses an active referral
# when one is on file, and otherwise files a minimal one with DDR FILER, the
# stock FileMan filer. Each run cancels the referral, reads the status back
# with DDR GETS ENTRY DATA, and then files it ACTIVE again with the same RPC,
# so the container ends as it began and a rerun reuses the same referral.
class ReferralCancelLiveTest < LiveSpec::Test
  writes!

  REFERRAL_FILE = "90001"
  FIXTURE_DFN = "990001"
  ACTIVE = "A"

  def test_cancel_files_the_cancelled_status_and_the_server_reads_it_back
    ien = active_referral
    begin
      result = RpmsRpc::Referral.cancel(ien)
      assert result[:success], "Referral.cancel(#{ien}) answered #{result.inspect}"
      assert_equal RpmsRpc::Referral::CANCELLED_STATUS, status_of(ien), "referral #{ien} is not cancelled after cancel"
      puts "\n#{persona}: referral #{ien} cancelled, status read back #{status_of(ien).inspect}"
    ensure
      restore_active(ien)
    end
  end

  # BMC REFERRAL STATUS UPDATE checks the IEN and FileMan refuses an entry
  # not on file (UPDTSTRF^BMCRPC3, BMCRPC3.m:181-184). On builds without
  # rpms-ops#702 the refusal path QUITs with a value under a broker that DOes
  # the tag, so the broker answers an M error at that line instead of
  # "~`0^message". Either way nothing is filed and cancel does not succeed.
  def test_cancel_of_a_referral_not_on_file_is_refused
    begin
      result = RpmsRpc::Referral.cancel("999999999")
      refute result[:success], "cancel of a referral not on file answered success: #{result.inspect}"
    rescue RpmsRpc::Client::RpcError => e
      assert_match(/UPDTSTRF\+\d+\^BMCRPC3/, e.message, "the refusal came from somewhere other than UPDTSTRF^BMCRPC3")
    end
    assert_nil status_of("999999999"), "a referral 999999999 is on file after the refused cancel"
  end

  def test_cancel_of_a_non_ien_answers_without_the_wire
    refute RpmsRpc::Referral.cancel(nil)[:success]
    refute RpmsRpc::Referral.cancel("0")[:success]
  end

  private

  # STATUS OF REFERRAL, internal, or nil when the entry is not on file.
  def status_of(ien)
    entry = RpmsRpc::DdrFileman.gets_entry(file: REFERRAL_FILE, iens: "#{ien},", fields: ".15", flags: "I")
    flunk "DDR GETS ENTRY DATA on file #{REFERRAL_FILE} gave no reply" if entry.nil?
    return nil if entry[:error]

    entry[:fields].dig(".15", :internal)
  end

  def active_referral
    listed = RpmsRpc::DdrFileman.lister(file: REFERRAL_FILE, fields: "@;.15", flags: "IP")
    flunk "DDR LISTER on file #{REFERRAL_FILE} gave no reply" if listed.nil?
    flunk "DDR LISTER on file #{REFERRAL_FILE} answered an error" if listed[:error]

    found = listed[:entries].find { |e| e[:pieces].first == ACTIVE }
    found ? found[:ien] : file_fixture
  end

  # A minimal ACTIVE referral (date, patient, in-house, outpatient), filed
  # with DDR FILER because BMC ADD REFERRAL cannot be called on YottaDB.
  def file_fixture
    values = { ".01" => today_fileman, ".03" => FIXTURE_DFN, ".04" => "N", ".14" => "O", ".15" => ACTIVE }
    rows = values.map { |field, value| { file: REFERRAL_FILE, field: field, iens: "+1,", value: value } }
    filed = RpmsRpc::DdrFileman.filer(mode: "ADD", rows: rows)
    assert filed && filed[:success], "DDR FILER could not file a fixture referral: #{filed.inspect}"
    filed[:iens].fetch(1)
  end

  def today_fileman
    d = Date.today
    format("%<y>03d%<m>02d%<d>02d", y: d.year - 1700, m: d.month, d: d.day)
  end

  def restore_active(ien)
    client.with_context(RpmsRpc::Referral::CONTEXT) { RpmsRpc::Referral.update_status(ien, ACTIVE) }
    assert_equal ACTIVE, status_of(ien), "referral #{ien} could not be filed ACTIVE again; the container is left with it cancelled"
  end
end
