# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/referral"
require "rpms_rpc/api/ddr_fileman"

# Referral.record_follow_up files a confirmed follow-up on an open referral,
# the date of service and a case note, through BMC UPDATE REFERRAL
# (UPDREFRL^BMCRPC2, FOIA BMCRPC2.m:158-252) under BMCRPC, and
# Referral.follow_up_state reads it back (rpms-rpc#722).
#
# UPDREFRL has 36 formals with RSLT. YottaDB takes at most 32 actual
# arguments, so the full call fails (the last test here proves it), and
# record_follow_up sends 30 parameters: REFIEN through CN.
#
# It WRITES, so it runs only against a disposable local container. It needs
# an ACTIVE referral with no EHR referral link (1303). Like
# referral_cancel_live_test.rb, it reuses one when one is on file and
# otherwise files a minimal one with DDR FILER, because BMC ADD REFERRAL
# cannot be called on YottaDB. Each test restores what it changed: the date
# of service (1106) as read before, the case note it added is deleted, and a
# cancelled referral is filed ACTIVE again. The lock test signs on a second
# session to hold the entry's lock. DATE LAST UPDATED (.27) keeps the
# run's date, and UPDREFRL sends its MailMan notice (SENDXM^BMCRPC3).
#
# Observed live on the pinned build, and guarded here: UPDREFRL files the
# time as typed ("09:30" was filed "3261204.0930", not FileMan's
# "3261204.093"), and it deletes 1106 when SCHWIDAY carries no date, so a
# note-only follow-up has to resend the date on file.
#
#   bin/cloud_rpms up
#   LIVE_DISPOSABLE=1 BROKER_HOST=127.0.0.1 BROKER_PORT=9100 PERSONA=PMD123 \
#   RPMS_ACCESS=PMD123 RPMS_VERIFY='PMD123!!' \
#   bundle exec ruby -Ilib -Itest test/live/referral_follow_up_live_test.rb
class ReferralFollowUpLiveTest < LiveSpec::Test
  writes!

  REFERRAL_FILE = "90001"
  COMMENTS_FILE = "90001.03"
  FIXTURE_DFN = "990001"
  ACTIVE = "A"
  APPOINTMENT = Date.new(2026, 12, 4)
  FILED = "3261204.093" # 12/4/2026 09:30, FileMan internal: no trailing zero
  NOTE = "SYNTHETIC rpms-rpc#722 live spec: patient says the cardiology appointment is booked for 12/4."

  def test_a_follow_up_files_the_date_and_a_case_note_and_reads_back
    ien = active_referral
    before = RpmsRpc::Referral.follow_up_state(ien)
    refute_nil before, "follow_up_state(#{ien}) read nothing before the update"
    untouched = untouched_fields(ien)
    begin
      result = RpmsRpc::Referral.record_follow_up(ien, appointment_on: APPOINTMENT, time: "09:30", case_note: NOTE)
      assert result[:success], "record_follow_up(#{ien}) answered #{result.inspect}"

      after = RpmsRpc::Referral.follow_up_state(ien)
      assert_equal ACTIVE, after[:status], "the update changed the referral's status"
      assert_equal FILED, after[:appointment], "1106 does not read back 12/4/2026 09:30 in FileMan's form"
      assert_equal FILED, result[:appointment]
      added = after[:case_notes].map { |n| n[:ien] } - before[:case_notes].map { |n| n[:ien] }
      assert_equal 1, added.size, "expected one new CASE note, got #{added.inspect}"
      assert_equal added.first, result[:case_note_ien]
      note = after[:case_notes].find { |n| n[:ien] == added.first }
      assert_equal NOTE, note[:text].strip
      assert_equal untouched, untouched_fields(ien), "fields the update should resend as read changed"
      puts "\n#{persona}: referral #{ien} 1106=#{after[:appointment]} case note #{added.first}: #{note[:text].strip}"
    ensure
      restore(ien, before, added)
    end
  end

  # UPDREFRL deletes 1106 when it gets no date (BMCRPC2.m:216-217): it did,
  # live, before record_follow_up resent the date on file.
  def test_a_note_only_follow_up_keeps_the_date_of_service
    ien = active_referral
    before = RpmsRpc::Referral.follow_up_state(ien)
    refute_nil before, "follow_up_state(#{ien}) read nothing before the update"
    untouched = untouched_fields(ien)
    begin
      dated = RpmsRpc::Referral.record_follow_up(ien, appointment_on: APPOINTMENT, time: "09:30")
      assert dated[:success], "record_follow_up(#{ien}) with a date answered #{dated.inspect}"
      assert_nil dated[:case_note_ien]
      assert_equal FILED, RpmsRpc::Referral.follow_up_state(ien)[:appointment]

      result = RpmsRpc::Referral.record_follow_up(ien, case_note: NOTE)
      assert result[:success], "note-only record_follow_up(#{ien}) answered #{result.inspect}"

      after = RpmsRpc::Referral.follow_up_state(ien)
      assert_equal FILED, after[:appointment], "the note-only follow-up changed the date of service"
      assert_equal FILED, result[:appointment]
      added = after[:case_notes].map { |n| n[:ien] } - before[:case_notes].map { |n| n[:ien] }
      assert_equal [ result[:case_note_ien] ], added, "expected one new CASE note"
      assert_equal untouched, untouched_fields(ien), "fields the update should resend as read changed"
      puts "\n#{persona}: referral #{ien} 1106=#{after[:appointment]} kept by a note-only follow-up (note #{added.first})"
    ensure
      restore(ien, before, added)
    end
  end

  def test_a_closed_referral_is_refused_before_anything_is_written
    ien = active_referral
    begin
      assert RpmsRpc::Referral.cancel(ien)[:success], "could not cancel referral #{ien} for the test"
      result = RpmsRpc::Referral.record_follow_up(ien, appointment_on: APPOINTMENT, time: "09:30", case_note: NOTE)
      refute result[:success]
      assert_equal :closed, result[:error]
    ensure
      client.with_context(RpmsRpc::Referral::CONTEXT) { RpmsRpc::Referral.update_status(ien, ACTIVE) }
      assert_equal ACTIVE, RpmsRpc::Referral.follow_up_state(ien)[:status], "referral #{ien} left cancelled"
    end
  end

  # UPDREFRL takes no lock; record_follow_up locks ^BMCREF(ien) around its
  # reads, rewrite and read-back. A second broker session (its own M
  # process) holds that lock here: the call waits out its timeout, answers
  # :locked and changes nothing.
  def test_a_referral_locked_by_another_session_is_refused_and_nothing_changes
    ien = active_referral
    node = "^BMCREF(#{ien})"
    before = RpmsRpc::Referral.follow_up_state(ien)
    refute_nil before, "follow_up_state(#{ien}) read nothing before the update"
    untouched = untouched_fields(ien)
    mine = client
    other = sign_on # a second session; sign_on also makes it RpmsRpc.client
    assert_equal true, RpmsRpc::DdrFileman.lock(node: node, timeout: 5), "the second session could not lock #{node}"
    RpmsRpc.configure { |cfg| cfg.client = mine }

    result = RpmsRpc::Referral.record_follow_up(ien, appointment_on: APPOINTMENT, time: "09:30", case_note: NOTE)
    after = RpmsRpc::Referral.follow_up_state(ien)
    assert_equal [ false, :locked, nil ], result.values_at(:success, :error, :raw), result.inspect
    assert_equal before, after, "the referral changed under another session's lock"
    assert_equal untouched, untouched_fields(ien)
    puts "\n#{persona}: referral #{ien} locked by a second session: #{result[:message]}"
  ensure
    if other
      RpmsRpc.configure { |cfg| cfg.client = other }
      RpmsRpc::DdrFileman.unlock(node: node)
      other.disconnect
    end
    RpmsRpc.configure { |cfg| cfg.client = mine } if mine
    restore(ien, before, after[:case_notes].map { |n| n[:ien] } - before[:case_notes].map { |n| n[:ien] }) if before && after
  end

  def test_a_referral_not_on_file_is_a_typed_refusal
    result = RpmsRpc::Referral.record_follow_up("999999999", case_note: NOTE)
    refute result[:success]
    assert_equal :not_found, result[:error]
  end

  # The full UPDREFRL frame is 36 actuals: YottaDB refuses it before the
  # routine runs, so nothing is filed.
  def test_the_full_frame_is_over_yottadbs_actual_argument_limit
    ien = active_referral
    params = [ ien ] + Array.new(34, "")
    error = assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Referral.update(*params) }
    assert_match(/MAXACTARG/, error.message)
  end

  private

  # Fields the update resends or must leave alone: 1302, 401-412, and .04,
  # .06, .14 (the empty TYPE, RQPR and INOROUT are skipped by the routine).
  def untouched_fields(ien)
    fields = ".04;.06;.14;1302;#{RpmsRpc::Referral::INCLUDE_FLAG_FIELDS.sort.join(';')}"
    entry = RpmsRpc::DdrFileman.gets_entry(file: REFERRAL_FILE, iens: "#{ien},", fields: fields, flags: "I")
    flunk "DDR GETS ENTRY DATA on referral #{ien} answered #{entry.inspect}" if entry.nil? || entry[:error]
    entry[:fields].transform_values { |v| v[:internal] }
  end

  def active_referral
    listed = RpmsRpc::DdrFileman.lister(file: REFERRAL_FILE, fields: "@;.15;1303", flags: "IP")
    flunk "DDR LISTER on file #{REFERRAL_FILE} answered #{listed.inspect}" if listed.nil? || listed[:error]

    found = listed[:entries].find { |e| e[:pieces][0] == ACTIVE && e[:pieces][1].to_s.empty? }
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

  def restore(ien, before, added_notes)
    rows = [ { file: REFERRAL_FILE, field: "1106", iens: "#{ien},", value: before[:appointment].empty? ? "@" : before[:appointment] } ]
    Array(added_notes).each { |n| rows << { file: COMMENTS_FILE, field: ".01", iens: "#{n},", value: "@" } }
    restored = RpmsRpc::DdrFileman.filer(mode: "EDIT", rows: rows)
    assert restored && restored[:success], "could not restore referral #{ien}: #{restored.inspect}"
    after = RpmsRpc::Referral.follow_up_state(ien)
    assert_equal before[:appointment], after[:appointment], "referral #{ien} 1106 not restored"
    assert_equal before[:case_notes].map { |n| n[:ien] }, after[:case_notes].map { |n| n[:ien] }, "case note not removed"
  end
end
