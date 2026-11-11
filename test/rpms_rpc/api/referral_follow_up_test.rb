# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/referral"

# Referral.record_follow_up files a confirmed follow-up (date of service and a
# case note) through BMC UPDATE REFERRAL, UPDREFRL^BMCRPC2 (FOIA BMCRPC2.m:158),
# and follow_up_state reads it back (rpms-rpc#722). Every reply here is
# seeded, so these tests prove the frame and the guards, not the build:
# test/live/referral_follow_up_live_test.rb is the live proof.
class ReferralFollowUpTest < Minitest::Test
  IEN = "7"
  SIGN_ON_CONTEXT = "CIAV VUECENTRIC"
  FLAG_FIELDS = %w[401 402 403 404 405 406 407 408 409 410 411 412].freeze

  def teardown
    RpmsRpc.reset!
  end

  def test_an_open_referral_gets_thirty_parameters_under_bmcrpc
    mock = seeded_mock

    result = RpmsRpc::Referral.record_follow_up(IEN, appointment_on: Date.new(2026, 12, 4), time: "09:30",
                                                     case_note: "Patient says the cardiology appointment is booked for 12/4.")

    assert result[:success], result.inspect
    call = mock.received_calls.find { |c| c[:rpc] == "BMC UPDATE REFERRAL" }
    params = call[:params].to_a
    assert_equal 30, params.size, "REFIEN through CN: 31 actuals with RSLT, under YottaDB's 32"
    assert_operator params.size + 1, :<=, RpmsRpc::Referral::YDB_MAX_ACTUALS
    assert_equal IEN, params[0]
    assert_equal [ "" ] * 9, params[1..9], "TYPE through NOTESCHD empty, so UPDREFRL leaves them as filed"
    assert_equal "", params[10], "HXCMNTS empty: no medical-history note"
    assert_equal "14^12/04/2026@09:30", params[11], "SCHWIDAY: days kept, then the date of service"
    # Formal order ICSRP IFSHT IHLSM IHSPH IEKG ILBRP IPCC IPRNL ITUBL ICLNT IXRYR IXRYF
    # is fields 411 405 406 408 407 412 401 403 404 402 409 410, resent as read.
    assert_equal %w[Y N Y N N Y Y N N Y N N], params[12..23]
    assert_equal [ "", "", "", "" ], params[24..27], "BCMNTS OTHRTYP SNMDCT PROB"
    assert_equal "SYNTHETIC TERM", params[28], "SNMDST resent: UPDREFRL kills the SNOMED multiple"
    assert_equal "Patient says the cardiology appointment is booked for 12/4.", params[29]
    assert_equal "BMCRPC", call[:context]
    ddr = mock.received_calls.select { |c| c[:rpc].start_with?("DDR") }
    refute_empty ddr
    assert(ddr.all? { |c| c[:context] == SIGN_ON_CONTEXT }, "the DDR reads stay in the caller's option")
    assert_equal SIGN_ON_CONTEXT, mock.current_context
  end

  def test_a_note_only_follow_up_sends_no_date
    mock = seeded_mock

    RpmsRpc::Referral.record_follow_up(IEN, case_note: "left a message\nwill call back ~ Monday")

    params = mock.received_calls.find { |c| c[:rpc] == "BMC UPDATE REFERRAL" }[:params].to_a
    assert_equal "", params[11]
    assert_equal "left a message will call back - Monday", params[29], "one line, no ~ (the RCIS WP splitter)"
  end

  def test_a_closed_referral_is_refused_before_the_update
    mock = seeded_mock(status: "C1")

    result = RpmsRpc::Referral.record_follow_up(IEN, appointment_on: Date.new(2026, 12, 4))

    refute result[:success]
    assert_equal :closed, result[:error]
    refute(mock.received_calls.any? { |c| c[:rpc] == "BMC UPDATE REFERRAL" })
  end

  def test_a_referral_linked_to_an_ehr_referral_is_refused
    mock = seeded_mock(linked: "55")

    result = RpmsRpc::Referral.record_follow_up(IEN, case_note: "x")

    assert_equal :linked_ehr_referral, result[:error]
    refute(mock.received_calls.any? { |c| c[:rpc] == "BMC UPDATE REFERRAL" })
  end

  def test_several_snomed_terms_are_refused
    mock = seeded_mock(terms: [ "ONE", "TWO" ])

    result = RpmsRpc::Referral.record_follow_up(IEN, case_note: "x")

    assert_equal :several_snomed_terms, result[:error]
    refute(mock.received_calls.any? { |c| c[:rpc] == "BMC UPDATE REFERRAL" })
  end

  def test_a_referral_not_on_file_is_refused
    mock = RpmsRpc.mock!
    mock.instance_variable_set(:@current_context, SIGN_ON_CONTEXT)
    mock.seed(:ddr_gets_entry_data, gets_key, "[ERROR]\n[BEGIN_diERRORS]\n601^The entry does not exist.\n[END_diERRORS]")

    result = RpmsRpc::Referral.record_follow_up(IEN, case_note: "x")

    assert_equal :not_found, result[:error]
  end

  def test_refusals_without_the_wire
    RpmsRpc.mock!
    assert_equal :invalid_ien, RpmsRpc::Referral.record_follow_up("0", case_note: "x")[:error]
    assert_equal :nothing_to_file, RpmsRpc::Referral.record_follow_up(IEN)[:error]
    assert_raises(ArgumentError) { RpmsRpc::Referral.record_follow_up(IEN, appointment_on: "12/4") }
    assert_raises(ArgumentError) { RpmsRpc::Referral.record_follow_up(IEN, appointment_on: Date.today, time: "9am") }
    assert_empty RpmsRpc.client.received_calls
  end

  def test_the_routine_refusal_carries_its_message
    seeded_mock(reply: "~`0^Error updating referral:The value is not valid.")

    result = RpmsRpc::Referral.record_follow_up(IEN, case_note: "x")

    refute result[:success]
    assert_equal "Error updating referral:The value is not valid.", result[:message]
  end

  def test_follow_up_state_reads_status_date_and_case_notes
    mock = RpmsRpc.mock!
    mock.seed(:ddr_gets_entry_data, state_key,
              "[Data]\n90001^#{IEN},^.15^A\n90001^#{IEN},^1106^3261204.093")
    mock.seed(:ddr_lister, notes_key, "[Data]\n31^3261111^#{IEN}^C")
    mock.seed(:ddr_gets_entry_data, note_text_key("31"),
              "[Data]\n90001.03^31,^1^[WORD PROCESSING]\nbooked for 12/4\n$$END$$")

    state = RpmsRpc::Referral.follow_up_state(IEN)

    assert_equal "A", state[:status]
    assert_equal "3261204.093", state[:appointment]
    assert_equal [ { ien: "31", date: "3261111", text: "booked for 12/4" } ], state[:case_notes]
  end

  private

  def seeded_mock(status: "A", linked: "", terms: [ "SYNTHETIC TERM" ], reply: "~`1")
    mock = RpmsRpc.mock!
    mock.instance_variable_set(:@current_context, SIGN_ON_CONTEXT)
    flags = %w[401 Y 402 Y 403 N 404 N 405 N 406 Y 407 N 408 N 409 N 410 N 411 Y 412 Y].each_slice(2).to_h
    lines = [ "90001^#{IEN},^.15^#{status}", "90001^#{IEN},^1302^14", "90001^#{IEN},^1303^#{linked}" ] +
            FLAG_FIELDS.map { |f| "90001^#{IEN},^#{f}^#{flags[f]}" }
    mock.seed(:ddr_gets_entry_data, gets_key, "[Data]\n#{lines.join("\n")}")
    rows = terms.each_with_index.map { |t, i| "#{i + 1}^#{t}" }
    mock.seed(:ddr_lister, snomed_key, "[Data]\n#{rows.join("\n")}")
    mock.seed_scalar(:bmc_update_referral, IEN, reply)
    mock
  end

  def gets_key
    RpmsRpc::DdrFileman.gets_entry_param(file: "90001", iens: "#{IEN},",
                                         fields: ".15;1302;1303;#{FLAG_FIELDS.join(';')}", flags: "I").to_s
  end

  def state_key
    RpmsRpc::DdrFileman.gets_entry_param(file: "90001", iens: "#{IEN},", fields: ".15;1106", flags: "I").to_s
  end

  def snomed_key
    RpmsRpc::DdrFileman.lister_param(file: "90001.22", iens: ",#{IEN},", fields: "@;.01", flags: "IP").to_s
  end

  def notes_key
    RpmsRpc::DdrFileman.lister_param(file: "90001.03", fields: "@;.01;.03;.05", flags: "IP",
                                     screen: "I $P(^(0),U,3)=#{IEN},$P(^(0),U,5)=\"C\"").to_s
  end

  def note_text_key(ien)
    RpmsRpc::DdrFileman.gets_entry_param(file: "90001.03", iens: "#{ien},", fields: "1", flags: "I").to_s
  end
end
