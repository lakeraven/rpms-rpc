# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/referral"

# Referral.record_follow_up files a confirmed follow-up (date of service and a
# case note) through BMC UPDATE REFERRAL, UPDREFRL^BMCRPC2 (FOIA BMCRPC2.m:158),
# and follow_up_state reads it back (rpms-rpc#722). The mock here answers DDR
# GETS ENTRY DATA and DDR LISTER from one in-memory referral, and BMC UPDATE
# REFERRAL changes that referral the way UPDREFRL does (see #updrefrl), so
# these tests prove the frame, the guards and the read-back, not the build:
# test/live/referral_follow_up_live_test.rb is the live proof.
class ReferralFollowUpTest < Minitest::Test
  IEN = "7"
  SIGN_ON_CONTEXT = "CIAV VUECENTRIC"
  UPDATE_RPC = "BMC UPDATE REFERRAL"
  FLAGS = %w[401 Y 402 Y 403 N 404 N 405 N 406 Y 407 N 408 N 409 N 410 N 411 Y 412 Y].each_slice(2).to_h.freeze
  DAY = Date.new(2026, 12, 4)
  NOTE = "Patient says the cardiology appointment is booked for 12/4."
  BAD_IENS = [ "1,2", "7abc", "+7", "0", "", nil ].freeze
  # DDR LISTER replies that are not a complete list of the CASE notes.
  UNREAD_NOTES = {
    "no reply" => [],
    "an error" => [ "[Errors]", "The file is not available." ],
    "a truncated list" => [ "[Misc]", "MORE^3261111^31", "[Data]", "31^3261111^#{IEN}^C" ]
  }.freeze

  def teardown
    RpmsRpc.reset!
  end

  def test_an_open_referral_gets_thirty_parameters_under_bmcrpc_and_is_read_back
    mock, = fake_referral

    result = RpmsRpc::Referral.record_follow_up(IEN, appointment_on: DAY, time: "09:30", case_note: NOTE)

    assert_equal({ success: true, appointment: "3261204.093", case_note_ien: "32" }, result.except(:raw), result.inspect)
    assert_equal "~`1", result[:raw].to_s
    call = update_calls(mock).first
    params = call[:params].to_a
    assert_equal 30, params.size, "REFIEN through CN: 31 actuals with RSLT, under YottaDB's 32"
    assert_operator params.size + 1, :<=, RpmsRpc::Referral::YDB_MAX_ACTUALS
    assert_equal IEN, params[0]
    assert_equal [ "" ] * 9, params[1..9], "TYPE through NOTESCHD empty, so UPDREFRL leaves them as filed"
    assert_equal "", params[10], "HXCMNTS empty: no medical-history note"
    assert_equal "14^12/04/2026@093", params[11], "SCHWIDAY: days kept, then the date and the canonical time digits"
    # Formal order ICSRP IFSHT IHLSM IHSPH IEKG ILBRP IPCC IPRNL ITUBL ICLNT IXRYR IXRYF
    # is fields 411 405 406 408 407 412 401 403 404 402 409 410, resent as read.
    assert_equal %w[Y N Y N N Y Y N N Y N N], params[12..23]
    assert_equal [ "", "", "", "" ], params[24..27], "BCMNTS OTHRTYP SNMDCT PROB"
    assert_equal "SYNTHETIC TERM", params[28], "SNMDST resent: UPDREFRL kills the SNOMED multiple"
    assert_equal NOTE, params[29]
    assert_equal "BMCRPC", call[:context]
    rpcs = mock.received_calls.map { |c| c[:rpc] }
    assert_includes rpcs[(rpcs.index(UPDATE_RPC) + 1)..], "DDR GETS ENTRY DATA", "the referral is read back after the update"
    ddr = mock.received_calls.select { |c| c[:rpc].start_with?("DDR") }
    assert(ddr.all? { |c| c[:context] == SIGN_ON_CONTEXT }, "the DDR reads stay in the caller's option")
    assert_equal SIGN_ON_CONTEXT, mock.current_context
  end

  # UPDREFRL files the time as typed (no E flag): only canonical digits go out.
  def test_the_time_is_sent_as_canonical_fileman_digits
    { "12:00" => "12", "10:05" => "1005", "00:30" => "003", "23:59" => "2359" }.each do |time, digits|
      mock, = fake_referral
      result = RpmsRpc::Referral.record_follow_up(IEN, appointment_on: DAY, time: time)

      assert_equal "14^12/04/2026@#{digits}", update_calls(mock).first[:params].to_a[11], time
      assert_equal [ true, "3261204.#{digits}", nil ], result.values_at(:success, :appointment, :case_note_ien), time
    end
  end

  # UPDREFRL deletes 1106 when SCHWIDAY carries no date (BMCRPC2.m:216-217).
  def test_a_note_only_follow_up_resends_the_date_of_service_on_file
    { "3261204.093" => "14^12/04/2026@093", "3261204.12" => "14^12/04/2026@12",
      "3261204.0930" => "14^12/04/2026@0930", "" => "" }.each do |on_file, schwiday|
      mock, = fake_referral({ "1106" => on_file })
      result = RpmsRpc::Referral.record_follow_up(IEN, case_note: "left a message\nwill call back ~ Monday")

      params = update_calls(mock).first[:params].to_a
      assert_equal schwiday, params[11], "1106 #{on_file.inspect} on file"
      assert_equal "left a message will call back - Monday", params[29], "one line, no ~ (the RCIS WP splitter)"
      assert_equal [ true, "32" ], result.values_at(:success, :case_note_ien), result.inspect
      assert_equal on_file, result[:appointment].to_s, "1106 must survive a note-only follow-up"
    end
  end

  # Resent without a time the routine would file "3261204." (a trailing dot).
  def test_a_note_only_follow_up_on_a_date_without_a_time_is_refused
    mock, = fake_referral({ "1106" => "3261204" })

    result = RpmsRpc::Referral.record_follow_up(IEN, case_note: NOTE)

    assert_equal [ false, :date_only_appointment ], result.values_at(:success, :error), result.inspect
    assert_empty update_calls(mock)
  end

  # The reply is not evidence: "~`1" with any of these read-backs is :not_filed.
  def test_a_success_reply_is_not_filed_when_the_read_back_differs
    drifts = {
      "1106 not filed" => ->(r, _p) { r[:fields]["1106"] = "" },
      "1106 filed as another value" => ->(r, _p) { r[:fields]["1106"] = "3261204.0930" },
      "no case note" => ->(r, _p) { r[:notes].pop },
      "two case notes" => ->(r, p) { add_note(r, p[29]) },
      "a case note with another text" => ->(r, _p) { r[:notes].last[:text] = "something else" },
      "1302 changed" => ->(r, _p) { r[:fields]["1302"] = "" },
      "an INCLUDE flag lost" => ->(r, _p) { r[:fields]["401"] = "" },
      "the SNOMED CT term lost" => ->(r, _p) { r[:terms].clear }
    }
    drifts.each do |what, drift|
      fake_referral do |record, params|
        updrefrl(record, params)
        drift.call(record, params)
      end
      result = RpmsRpc::Referral.record_follow_up(IEN, appointment_on: DAY, time: "09:30", case_note: NOTE)

      assert_equal [ false, :not_filed ], result.values_at(:success, :error), "#{what}: #{result.inspect}"
      assert_kind_of String, result[:message], what
      assert_equal "~`1", result[:raw].to_s, what
    end
  end

  def test_a_routine_refusal_is_not_filed_and_carries_its_message
    fake_referral(reply: "~`0^Error updating referral:The value is not valid.") { |_record, _params| }

    result = RpmsRpc::Referral.record_follow_up(IEN, case_note: NOTE)

    assert_equal [ false, :not_filed ], result.values_at(:success, :error), result.inspect
    assert_includes result[:message], "Error updating referral:The value is not valid."
    assert_equal "~`0^Error updating referral:The value is not valid.", result[:raw].to_s
  end

  # UPDREFRL NEWs FDA and ERR1 (BMCRPC2.m:161), so only the read-back decides.
  def test_a_refusal_reply_is_a_success_when_everything_reads_back
    fake_referral(reply: "~`0^Error updating referral:stale")

    result = RpmsRpc::Referral.record_follow_up(IEN, appointment_on: DAY, time: "09:30", case_note: NOTE)

    assert_equal [ true, "3261204.093", "32" ], result.values_at(:success, :appointment, :case_note_ien), result.inspect
  end

  def test_unreadable_case_notes_are_refused_before_the_update
    UNREAD_NOTES.each do |what, reply|
      mock, = fake_referral(notes_reply: reply)
      result = RpmsRpc::Referral.record_follow_up(IEN, appointment_on: DAY, time: "09:30", case_note: NOTE)

      assert_equal [ false, :unread ], result.values_at(:success, :error), "#{what}: #{result.inspect}"
      assert_empty update_calls(mock), what
    end
  end

  def test_a_closed_referral_is_refused_before_the_update
    mock, = fake_referral({ ".15" => "C1" })

    result = RpmsRpc::Referral.record_follow_up(IEN, appointment_on: DAY, time: "09:30")

    refute result[:success]
    assert_equal :closed, result[:error]
    assert_empty update_calls(mock)
  end

  def test_a_referral_linked_to_an_ehr_referral_is_refused
    mock, = fake_referral({ "1303" => "55" })

    assert_equal :linked_ehr_referral, RpmsRpc::Referral.record_follow_up(IEN, case_note: "x")[:error]
    assert_empty update_calls(mock)
  end

  def test_several_snomed_terms_are_refused
    mock, = fake_referral(terms: [ "ONE", "TWO" ])

    assert_equal :several_snomed_terms, RpmsRpc::Referral.record_follow_up(IEN, case_note: "x")[:error]
    assert_empty update_calls(mock)
  end

  def test_a_referral_not_on_file_is_refused
    mock, = fake_referral(nil)

    assert_equal :not_found, RpmsRpc::Referral.record_follow_up(IEN, case_note: "x")[:error]
    assert_empty update_calls(mock)
  end

  # "1,2".to_i is 1 and "+7".to_i is 7: the IEN goes into an IENS, so only digits pass.
  def test_a_bad_ien_is_refused_without_the_wire
    mock, = fake_referral
    BAD_IENS.each do |ien|
      result = RpmsRpc::Referral.record_follow_up(ien, case_note: "x")
      assert_equal [ false, :invalid_ien ], result.values_at(:success, :error), ien.inspect
      assert_nil RpmsRpc::Referral.follow_up_state(ien), ien.inspect
    end
    assert_empty mock.received_calls
  end

  # No default time: a date-only confirmation must not invent noon.
  def test_refusals_without_the_wire
    mock, = fake_referral
    assert_equal :nothing_to_file, RpmsRpc::Referral.record_follow_up(IEN)[:error]
    assert_raises(ArgumentError) { RpmsRpc::Referral.record_follow_up(IEN, appointment_on: "12/4", time: "09:30") }
    assert_raises(ArgumentError) { RpmsRpc::Referral.record_follow_up(IEN, appointment_on: DAY) }
    assert_raises(ArgumentError) { RpmsRpc::Referral.record_follow_up(IEN, appointment_on: DAY, case_note: NOTE) }
    [ "9am", "9:30", "24:00", "00:00", "", nil ].each do |time|
      assert_raises(ArgumentError, time.inspect) { RpmsRpc::Referral.record_follow_up(IEN, appointment_on: DAY, time: time) }
    end
    assert_empty mock.received_calls
  end

  def test_follow_up_state_reads_status_date_and_case_notes
    fake_referral({ "1106" => "3261204.093" })

    state = RpmsRpc::Referral.follow_up_state(IEN)

    assert_equal "A", state[:status]
    assert_equal "3261204.093", state[:appointment]
    assert_equal [ { ien: "31", date: "3261111", text: "booked for 12/4" } ], state[:case_notes]
  end

  # An unread list is nil, never []: [] says the referral has no CASE notes.
  def test_follow_up_state_has_nil_case_notes_when_the_list_cannot_be_read
    UNREAD_NOTES.each do |what, reply|
      fake_referral(notes_reply: reply)
      state = RpmsRpc::Referral.follow_up_state(IEN)

      assert_equal "A", state[:status], what
      assert state.key?(:case_notes), what
      assert_nil state[:case_notes], what
    end
  end

  private

  # A mock that answers from one referral: `fields` are its #90001 internal
  # values over the defaults (nil: not on file), `terms` its SNOMED CT
  # multiple, and it has one CASE note, 31. BMC UPDATE REFERRAL runs the
  # block on [record, params], or #updrefrl, and answers `reply`. notes_reply
  # replaces the DDR LISTER reply for the CASE notes. Returns [mock, record].
  def fake_referral(fields = {}, terms: [ "SYNTHETIC TERM" ], reply: "~`1", notes_reply: nil, &update)
    record = { fields: fields && { ".15" => "A", "1106" => "", "1302" => "14", "1303" => "" }.merge(FLAGS, fields),
               terms: terms.dup, notes: [ { ien: "31", date: "3261111", text: "booked for 12/4" } ] }
    update ||= method(:updrefrl)
    answer = lambda do |rpc, params|
      case rpc
      when "DDR GETS ENTRY DATA" then gets_reply(record, params.first)
      when "DDR LISTER" then lister_reply(record, params.first, notes_reply)
      when UPDATE_RPC then update.call(record, params).then { reply }
      else ""
      end
    end
    mock = RpmsRpc.mock!
    mock.instance_variable_set(:@current_context, SIGN_ON_CONTEXT)
    mock.define_singleton_method(:seeded_reply) { |rpc, *params| super(rpc, *params).then { answer.call(rpc, params) } }
    [ mock, record ]
  end

  # What UPDREFRL files on an open referral (BMCRPC2.m:182-233): 1106 from
  # SCHWIDAY's "date@time" with the time digits as sent, deleted when there
  # is no date; the INCLUDE flags and the SNOMED CT term as sent; CN as a
  # new CASE note.
  def updrefrl(record, params)
    days, on = params[11].to_s.split("^", 2)
    date, time = on.to_s.split("@", 2)
    month, day, year = date.to_s.split("/")
    record[:fields]["1302"] = days unless params[11].to_s.empty?
    record[:fields]["1106"] = date.to_s.empty? ? "" : "#{year.to_i - 1700}#{month}#{day}.#{time.to_s.delete(':')}"
    RpmsRpc::Referral::INCLUDE_FLAG_FIELDS.zip(params[12..23]) { |field, flag| record[:fields][field] = flag.to_s }
    record[:terms].replace([ params[28].to_s ].reject(&:empty?))
    add_note(record, params[29]) unless params[29].to_s.empty?
  end

  def add_note(record, text)
    record[:notes] << { ien: (record[:notes].map { |n| n[:ien].to_i }.max.to_i + 1).to_s, date: "3261114", text: text.to_s }
  end

  def gets_reply(record, param)
    file, ien = param["FILE"], param["IENS"].to_s.delete_suffix(",")
    values = file == "90001" ? (record[:fields] if ien == IEN) : note_values(record, ien)
    return [ "[ERROR]", "[BEGIN_diERRORS]", "601^The entry does not exist.", "[END_diERRORS]" ] if values.nil?

    rows = param["FIELDS"].split(";").flat_map do |field|
      next [ "#{file}^#{ien},^1^[WORD PROCESSING]", values["1"], "$$END$$" ] if file == "90001.03" && field == "1"

      "#{file}^#{ien},^#{field}^#{values[field]}"
    end
    [ "[Data]" ] + rows
  end

  def note_values(record, ien)
    note = record[:notes].find { |n| n[:ien] == ien }
    note && { ".01" => note[:date], ".03" => IEN, ".05" => "C", "1" => note[:text] }
  end

  def lister_reply(record, param, notes_reply)
    return [ "[Data]" ] + record[:terms].each_with_index.map { |term, i| "#{i + 1}^#{term}" } if param["FILE"] == "90001.22"
    return notes_reply if notes_reply

    fields = param["FIELDS"].split(";") - [ "@" ]
    [ "[Data]" ] + record[:notes].map { |n| ([ n[:ien] ] + note_values(record, n[:ien]).values_at(*fields)).join("^") }
  end

  def update_calls(mock)
    mock.received_calls.select { |c| c[:rpc] == UPDATE_RPC }
  end
end
