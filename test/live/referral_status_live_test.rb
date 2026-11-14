# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/referral"
require "rpms_rpc/api/ddr_fileman"

# Referral.record_status files a checked STATUS OF REFERRAL (#90001 .15)
# through BMC REFERRAL STATUS UPDATE (UPDTSTRF^BMCRPC3) under BMCRPC and
# decides success by reading .15 back (rpms-rpc#722). The routine files any
# string, and it does not NEW FDA or ERR1: FILE^DIE keeps a failed FDA
# (DIEF.m:24), so after one failed update in a broker session every later
# one re-files every write queued since and answers "~`0^...". record_status
# answers :session_poisoned for that reply.
#
# It WRITES, so it runs only against a disposable local container. Like
# referral_follow_up_live_test.rb it reuses ACTIVE referrals with no EHR
# referral link (1303), or files minimal ones with DDR FILER. Each test
# files ACTIVE again in `ensure`. Every test has its own broker session
# (LiveSpec::Test#setup), so the poisoned one ends with its test. The lock
# test signs on a second session to hold the entry's lock.
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

  # UPDTSTRF takes no lock; record_status locks ^BMCREF(ien) around its read,
  # update and read-back. A second broker session (its own M process) holds
  # that lock here: the call waits out its timeout, answers :locked and
  # files nothing.
  def test_a_referral_locked_by_another_session_is_refused_and_nothing_is_filed
    ien = active_referral
    node = "^BMCREF(#{ien})"
    mine = client
    other = sign_on # a second session; sign_on also makes it RpmsRpc.client
    assert_equal true, RpmsRpc::DdrFileman.lock(node: node, timeout: 5), "the second session could not lock #{node}"
    RpmsRpc.configure { |cfg| cfg.client = mine }

    result = RpmsRpc::Referral.record_status(ien, APPROVED)
    assert_equal [ false, :locked, nil ], result.values_at(:success, :error, :raw), result.inspect
    assert_equal ACTIVE, status_of(ien), "the update was filed under another session's lock"
    puts "\n#{persona}: referral #{ien} locked by a second session: #{result[:message]}"
  ensure
    if other
      RpmsRpc.configure { |cfg| cfg.client = other }
      RpmsRpc::DdrFileman.unlock(node: node)
      other.disconnect
    end
    RpmsRpc.configure { |cfg| cfg.client = mine } if mine
    restore_active(ien)
  end

  # One failed update leaves its FDA queued for this session. Every later
  # update re-files the queue: the second referral's update files the first
  # referral's A1 again, after DDR FILER had set it back to A.
  def test_a_failed_update_poisons_the_session_and_later_updates_refile_earlier_ones
    first, second = active_referrals(2)
    failed = RpmsRpc::Referral.update_status(UNKNOWN_IEN, RpmsRpc::Referral::CANCELLED_STATUS)
    refute failed[:success], "update_status on an unknown IEN answered #{failed.inspect}"

    poisoned = RpmsRpc::Referral.record_status(first, APPROVED)
    assert_equal [ false, :session_poisoned ], poisoned.values_at(:success, :error), poisoned.inspect
    assert_equal [ APPROVED, ACTIVE ], poisoned.values_at(:status, :previous_status), "the routine files while it refuses"
    assert_match(/\A~`0/, poisoned[:raw].to_s)
    assert_match(/session.*close/im, poisoned[:message])

    file_active(first)
    assert_equal ACTIVE, status_of(first), "DDR FILER did not set referral #{first} back to A"
    again = RpmsRpc::Referral.record_status(second, APPROVED)
    assert_equal [ false, :session_poisoned ], again.values_at(:success, :error), again.inspect
    assert_equal APPROVED, status_of(first), "the update of referral #{second} did not re-file referral #{first}'s queued A1"
    puts "\n#{persona}: after #{failed[:raw].inspect}, record_status(#{second}) re-filed referral #{first} A1: #{again[:raw].inspect}"
  ensure
    # A fresh session, and DDR FILER, which does not go through UPDTSTRF's FDA.
    @client&.disconnect
    @client = sign_on
    [ first, second ].compact.each { |ien| file_active(ien) }
    [ first, second ].compact.each { |ien| assert_equal ACTIVE, status_of(ien), "referral #{ien} not left ACTIVE" }
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

  def active_referral = active_referrals(1).first

  # `count` ACTIVE referrals with no EHR referral link, filing what is missing.
  def active_referrals(count)
    listed = RpmsRpc::DdrFileman.lister(file: REFERRAL_FILE, fields: "@;.15;1303", flags: "IP")
    flunk "DDR LISTER on file #{REFERRAL_FILE} answered #{listed.inspect}" if listed.nil? || listed[:error]

    found = listed[:entries].select { |e| e[:pieces][0] == ACTIVE && e[:pieces][1].to_s.empty? }.map { |e| e[:ien] }.first(count)
    found + Array.new(count - found.size) { file_fixture }
  end

  # .15 = "A" with DDR FILER: no UPDTSTRF, so nothing queued is re-filed.
  def file_active(ien)
    filed = RpmsRpc::DdrFileman.filer(mode: "EDIT", rows: [ { file: REFERRAL_FILE, field: ".15", iens: "#{ien},", value: ACTIVE } ])
    assert filed && filed[:success], "DDR FILER could not file referral #{ien} ACTIVE: #{filed.inspect}"
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
