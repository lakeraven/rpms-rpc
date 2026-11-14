# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/referral"
require "rpms_rpc/api/ddr_fileman"

# Referral.record_status files a checked STATUS OF REFERRAL (#90001 .15)
# through BMC REFERRAL STATUS UPDATE (UPDTSTRF^BMCRPC3) under BMCRPC and
# decides success by reading .15 back (rpms-rpc#722). The routine files any
# string, and it does not NEW ERR1: after one failed update in a broker
# session, every later one answers that same "~`0^..." while it files.
#
# It WRITES, so it runs only against a disposable local container. Like
# referral_follow_up_live_test.rb it reuses an ACTIVE referral with no EHR
# referral link (1303), or files a minimal one with DDR FILER. Each test
# files ACTIVE again in `ensure`.
#
#   bin/cloud_rpms up
#   LIVE_DISPOSABLE=1 BROKER_HOST=127.0.0.1 BROKER_PORT=9100 PERSONA=PMD123 \
#   RPMS_ACCESS=PMD123 RPMS_VERIFY='PMD123!!' \
#   bundle exec ruby -Ilib -Itest test/live/referral_status_live_test.rb
class ReferralStatusLiveTest < LiveSpec::Test
  writes!

  REFERRAL_FILE = "90001"
  FIXTURE_DFN = "990001"
  ACTIVE = "A"
  APPROVED = "A1"
  UNKNOWN_IEN = "999999999"
  STATUS_RPC = "BMC REFERRAL STATUS UPDATE"

  def test_a_status_change_reads_back_and_changes_back
    ien = active_referral
    approved = RpmsRpc::Referral.record_status(ien, APPROVED)
    assert approved[:success], "record_status(#{ien}, A1) answered #{approved.inspect}"
    assert_equal [ APPROVED, ACTIVE ], approved.values_at(:status, :previous_status)
    assert_equal APPROVED, status_of(ien)

    active = RpmsRpc::Referral.record_status(ien, ACTIVE)
    assert active[:success], "record_status(#{ien}, A) answered #{active.inspect}"
    assert_equal [ ACTIVE, APPROVED ], active.values_at(:status, :previous_status)
    assert_equal ACTIVE, status_of(ien)
    puts "\n#{persona}: referral #{ien} .15 A -> A1 (#{approved[:raw].inspect}) -> A (#{active[:raw].inspect})"
  ensure
    restore_active(ien)
  end

  def test_a_referral_not_on_file_is_a_typed_refusal
    result = RpmsRpc::Referral.record_status(UNKNOWN_IEN, ACTIVE)
    assert_equal [ false, :not_found ], result.values_at(:success, :error)
    assert_nil result[:raw], "the update was sent for a referral that is not on file"
  end

  # The routine would file "H" (it did, live): the guard is the only check.
  def test_a_status_outside_the_set_of_codes_is_refused_and_nothing_is_filed
    ien = active_referral
    result = RpmsRpc::Referral.record_status(ien, "H")
    assert_equal [ false, :invalid_status ], result.values_at(:success, :error)
    assert_equal ACTIVE, status_of(ien)
  ensure
    restore_active(ien)
  end

  def test_the_wrong_context_is_refused_by_the_broker_and_nothing_is_filed
    ien = active_referral
    error = assert_raises(RpmsRpc::Client::RpcRefusedError) do
      client.with_context("OR CPRS GUI CHART") { client.call_rpc(STATUS_RPC, ien, APPROVED) }
    end
    assert_match(/#{STATUS_RPC}/o, error.message)
    assert_equal ACTIVE, status_of(ien)
  ensure
    restore_active(ien)
  end

  # One failed update leaves ERR1 set for this session: the read-back decides.
  def test_a_stale_error_reply_in_the_same_session_is_still_a_success
    ien = active_referral
    failed = RpmsRpc::Referral.update_status(UNKNOWN_IEN, ACTIVE)
    refute failed[:success], "update_status on an unknown IEN answered #{failed.inspect}"

    result = RpmsRpc::Referral.record_status(ien, APPROVED)
    assert result[:success], "record_status after a failed update answered #{result.inspect}"
    assert_equal APPROVED, status_of(ien)
    puts "\n#{persona}: referral #{ien} filed A1, reply #{result[:raw].inspect} after #{failed[:raw].inspect}"
  ensure
    restore_active(ien)
  end

  private

  def status_of(ien)
    RpmsRpc::Referral.follow_up_state(ien)&.fetch(:status)
  end

  # ACTIVE again, with the raw writer, checked by the read-back alone.
  def restore_active(ien)
    return if ien.nil?
    RpmsRpc::Referral.update_status(ien, ACTIVE) unless status_of(ien) == ACTIVE
    assert_equal ACTIVE, status_of(ien), "referral #{ien} not left ACTIVE"
  end

  def active_referral
    listed = RpmsRpc::DdrFileman.lister(file: REFERRAL_FILE, fields: "@;.15;1303", flags: "IP")
    flunk "DDR LISTER on file #{REFERRAL_FILE} answered #{listed.inspect}" if listed.nil? || listed[:error]

    found = listed[:entries].find { |e| e[:pieces][0] == ACTIVE && e[:pieces][1].to_s.empty? }
    found ? found[:ien] : file_fixture
  end

  # A minimal ACTIVE referral: BMC ADD REFERRAL cannot be called on YottaDB.
  def file_fixture
    today = format("%03d%s", Date.today.year - 1700, Date.today.strftime("%m%d"))
    values = { ".01" => today, ".03" => FIXTURE_DFN, ".04" => "N", ".14" => "O", ".15" => ACTIVE }
    rows = values.map { |field, value| { file: REFERRAL_FILE, field: field, iens: "+1,", value: value } }
    filed = RpmsRpc::DdrFileman.filer(mode: "ADD", rows: rows)
    assert filed && filed[:success], "DDR FILER could not file a fixture referral: #{filed.inspect}"
    filed[:iens].fetch(1)
  end
end
