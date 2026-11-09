# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "yaml"
require "rpms_rpc/api/agg"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/registration"
require_relative "../captured_replies"

# rpms-rpc#418 registration rows: SOGI, MBI and sex through DDR FILER and
# LISTER, and the explicit not-supported surfaces for the insurance APIs RPMS
# handles only through unreached M routines.
#
# Each replay test runs one recorded flow (test/fixtures/captured_replies/
# registration-bprm418.yml): the gem run as PROFILE,REG (DUZ 207) on seed
# patient DFN 990042 on the pinned build, with every reply it got, in order.
# The gem dates DATE ENTERED rows with the client's today, so where a
# recorded frame carries the capture's day, the replay expects today in its
# place; every other piece of each frame must be exactly what the gem sent
# the build. The round trips, read back from the files, are proven by
# test/live/registration_bprm418_live_test.rb, including the eligibility
# cascade of set_sex, which no seed patient here has rows for.
class RegistrationBprm418Test < Minitest::Test
  Reg = RpmsRpc::Registration
  FM = RpmsRpc::FilemanDateParser
  SLUG = "registration-bprm418"
  DFN = 990_042
  NO_PATIENT = 98_765_432
  DUZ = "207"
  ROW_DATE = Date.new(2026, 10, 15)
  OTHER_DATE = Date.new(2026, 10, 16)
  DUPLICATE_DATE = Date.new(2026, 10, 17)
  MBI_EFFECTIVE = Date.new(2030, 6, 1)
  RETRY_SAFETY_YML = File.expand_path("../../../lib/rpms_rpc/retry_safety.yml", __dir__)

  # The day the flows ran: the DATE ENTERED the legal-sex row was filed with.
  CAPTURE_DAY = FM.parse_date(
    CapturedReplies.flow_calls(SLUG, "legal_new").find { |rpc, _| rpc == "DDR FILER" }.last[1].values
                   .find { |row| row.start_with?("9000001.9201^3^") }.split("^").last
  )

  def teardown
    RpmsRpc.reset!
  end

  def replay(flow = nil)
    @flow = flow
    script = flow ? CapturedReplies.flow_script(SLUG, flow) : {}
    @client = CapturedReplies::ReplayCiaClient.new(script).signed_on_as(DUZ)
    RpmsRpc.configure { |cfg| cfg.client = @client }
    @client
  end

  def today = FM.to_fileman(Date.today)

  # A recorded value with the capture's day in it, as the gem builds it today.
  def as_of_today(value)
    case value
    when String then value.gsub(FM.to_fileman(CAPTURE_DAY), today)
    when Array then value.map { |v| as_of_today(v) }
    when Hash then value.to_h { |k, v| [ k, as_of_today(v) ] }
    else value
    end
  end

  def sent = @client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params] ] }
  def rpcs_sent = sent.map(&:first)
  def filer_calls = sent.select { |rpc, _| rpc == "DDR FILER" }
  def filer_rows(index = 0) = filer_calls.fetch(index).last[1].values

  # The gem sent exactly the calls of the flow it replays, frame for frame.
  def assert_sends_the_recorded_flow
    assert_equal as_of_today(CapturedReplies.flow_calls(SLUG, @flow)), sent
  end

  def assert_refused(result, error)
    refute result[:success], result.inspect
    assert_equal error, result[:error], result.inspect
  end

  # -- set_gender_identity ----------------------------------------------------

  # A new date: the header and each value in one ADD, each value sub-entry
  # DINUM'd to its code IEN, field 2 filed empty when no value is OTH.
  def test_set_gender_identity_files_a_new_date_with_dinum_pins
    replay("gi_new")

    result = Reg.set_gender_identity(DFN, values: [ 7, 3 ], date: ROW_DATE)

    assert result[:success], result.inspect
    assert_equal [ "DDR GETS ENTRY DATA", "DDR GETS ENTRY DATA", "DDR LISTER", "DDR FILER" ], rpcs_sent
    _, (mode, rows, _, pins) = filer_calls.first
    assert_equal "ADD", mode
    assert_equal [ "9000001.9401^.01^+1,#{DFN},^3261015", "9000001.9401^2^+1,#{DFN},^",
                   "9000001.94011^.01^+2,+1,#{DFN},^7", "9000001.94011^.01^+3,+1,#{DFN},^3" ], rows.values
    assert_equal({ 1 => "3261015", 2 => "7", 3 => "3" }, pins)
    assert_sends_the_recorded_flow
  end

  # The same date again: the value list is read, 7 is removed with "@", 3 is
  # kept, and 9 is added; the header is filed at its existing IENS.
  def test_set_gender_identity_reconciles_the_values_of_an_existing_date
    replay("gi_existing")

    result = Reg.set_gender_identity(DFN, values: [ 3, 9 ], date: ROW_DATE)

    assert result[:success], result.inspect
    node = "3261015,#{DFN},"
    assert_equal [ "9000001.9401^.01^#{node}^3261015", "9000001.9401^2^#{node}^",
                   "9000001.94011^.01^7,#{node}^@", "9000001.94011^.01^+2,#{node}^9" ], filer_rows
    assert_sends_the_recorded_flow
  end

  def test_set_gender_identity_files_other_text_beside_the_oth_code
    replay("gi_other")

    result = Reg.set_gender_identity(DFN, values: [ 6 ], other: "synthetic other text", date: OTHER_DATE)

    assert result[:success], result.inspect
    assert_includes filer_rows, "9000001.9401^2^+1,#{DFN},^synthetic other text"
    assert_sends_the_recorded_flow
  end

  # Rewriting the OTH date without OTH files field 2 empty, so the text goes.
  def test_set_gender_identity_clears_other_text_on_an_existing_date_without_an_oth_value
    replay("gi_clear_other")

    result = Reg.set_gender_identity(DFN, values: [ 7 ], date: OTHER_DATE)

    assert result[:success], result.inspect
    assert_includes filer_rows, "9000001.9401^2^3261016,#{DFN},^"
    assert_includes filer_rows, "9000001.94011^.01^6,3261016,#{DFN},^@"
    assert_sends_the_recorded_flow
  end

  def test_set_gender_identity_files_a_repeated_value_once
    replay("gi_duplicates")

    result = Reg.set_gender_identity(DFN, values: [ 7, 7 ], date: DUPLICATE_DATE)

    assert result[:success], result.inspect
    assert_equal 1, filer_rows.count { |row| row.start_with?("9000001.94011^") }
    assert_sends_the_recorded_flow
  end

  # ASKU is not OTH, so other text beside it is refused after the code read.
  def test_set_gender_identity_refuses_other_text_when_no_chosen_value_is_the_other_code
    replay("gi_other_text_not_oth")

    result = Reg.set_gender_identity(DFN, values: [ 7 ], other: "synthetic", date: ROW_DATE)

    assert_refused(result, :invalid)
    assert_empty filer_calls
    assert_sends_the_recorded_flow
  end

  # DDR GETS answers [ERROR] for a code IEN the build does not have: nothing
  # is listed or filed.
  def test_set_gender_identity_refuses_an_unknown_code_ien_without_a_date_row_lookup
    replay("gi_unknown_code")

    result = Reg.set_gender_identity(DFN, values: [ 424_242 ], date: ROW_DATE)

    assert_refused(result, :invalid)
    assert_equal [ "DDR GETS ENTRY DATA" ], rpcs_sent
    assert_sends_the_recorded_flow
  end

  def test_set_gender_identity_refuses_other_text_that_must_not_reach_m_without_rpc
    [ "self^described", "@", "note\x01" ].each do |other|
      replay

      result = Reg.set_gender_identity(DFN, values: [ 6 ], other: other, date: ROW_DATE)

      assert_refused(result, :invalid)
      assert_empty rpcs_sent, other.inspect
    end
  end

  def test_set_gender_identity_refuses_a_bad_dfn_or_value_list_without_rpc
    [ [ "", [ 1 ] ], [ DFN, [] ], [ DFN, [ "7" ] ] ].each do |dfn, values|
      replay

      assert_refused(Reg.set_gender_identity(dfn, values: values), :invalid)
      assert_empty rpcs_sent, [ dfn, values ].inspect
    end
  end

  # -- set_sexual_orientation -------------------------------------------------

  def test_set_sexual_orientation_files_a_new_date_with_dinum_pins
    replay("so_new")

    result = Reg.set_sexual_orientation(DFN, values: [ 3, 5 ], date: ROW_DATE)

    assert result[:success], result.inspect
    assert_equal [ "9000001.9301^.01^+1,#{DFN},^3261015", "9000001.9301^2^+1,#{DFN},^",
                   "9000001.93011^.01^+2,+1,#{DFN},^3", "9000001.93011^.01^+3,+1,#{DFN},^5" ], filer_rows
    assert_sends_the_recorded_flow
  end

  def test_set_sexual_orientation_updates_an_existing_date_and_files_other_text_for_oth
    replay("so_existing")

    result = Reg.set_sexual_orientation(DFN, values: [ 5, 4 ], other: "synthetic other text", date: ROW_DATE)

    assert result[:success], result.inspect
    node = "3261015,#{DFN},"
    assert_includes filer_rows, "9000001.9301^2^#{node}^synthetic other text"
    assert_includes filer_rows, "9000001.93011^.01^3,#{node}^@"
    assert_includes filer_rows, "9000001.93011^.01^+2,#{node}^4"
    refute(filer_rows.any? { |row| row.include?("^.01^5,") || row.end_with?("^5") }, "5 is already stored")
    assert_sends_the_recorded_flow
  end

  def test_set_sexual_orientation_refuses_an_unknown_code_ien_without_a_date_row_lookup
    replay("so_unknown_code")

    result = Reg.set_sexual_orientation(DFN, values: [ 424_242 ], date: ROW_DATE)

    assert_refused(result, :invalid)
    assert_equal [ "DDR GETS ENTRY DATA" ], rpcs_sent
    assert_sends_the_recorded_flow
  end

  def test_set_sexual_orientation_refuses_blank_values_without_rpc
    replay

    assert_refused(Reg.set_sexual_orientation(DFN, values: [ nil ]), :invalid)
    assert_empty rpcs_sent
  end

  def test_set_sexual_orientation_refuses_other_text_that_must_not_reach_m_without_rpc
    [ "self^described", "@", "note\x01" ].each do |other|
      replay

      result = Reg.set_sexual_orientation(DFN, values: [ 4 ], other: other, date: ROW_DATE)

      assert_refused(result, :invalid)
      assert_empty rpcs_sent, other.inspect
    end
  end

  # -- set_legal_sex ----------------------------------------------------------

  def test_set_legal_sex_files_a_new_date_with_source_and_today_entered
    replay("legal_new")

    result = Reg.set_legal_sex(DFN, sex: "F", source: 30, date: ROW_DATE)

    assert result[:success], result.inspect
    node = "+1,#{DFN},"
    assert_equal [ "9000001.9201^.01^#{node}^3261015", "9000001.9201^1^#{node}^F",
                   "9000001.9201^2^#{node}^30", "9000001.9201^3^#{node}^#{today}" ], filer_rows
    assert_sends_the_recorded_flow
  end

  def test_set_legal_sex_edits_an_existing_date_row_in_edit_mode
    replay("legal_existing")

    result = Reg.set_legal_sex(DFN, sex: "X", source: 30, date: ROW_DATE)

    assert result[:success], result.inspect
    assert_equal "EDIT", filer_calls.first.last[0]
    assert_includes filer_rows, "9000001.9201^1^3261015,#{DFN},^X"
    assert_sends_the_recorded_flow
  end

  def test_set_legal_sex_refuses_an_invalid_sex_code_without_rpc
    replay

    assert_refused(Reg.set_legal_sex(DFN, sex: "U", source: 30), :invalid)
    assert_empty rpcs_sent
  end

  # -- add_mbi / mbis ----------------------------------------------------------

  def test_add_mbi_files_an_upcased_mbi_with_the_signed_on_duz
    replay("mbi_new")

    result = Reg.add_mbi(DFN, mbi: "1eg4te5mk73", effective_date: MBI_EFFECTIVE, source: 1)

    assert result[:success], result.inspect
    node = "+1,#{DFN},"
    assert_equal [ "9000001.44^.01^#{node}^3300601", "9000001.44^1^#{node}^1EG4TE5MK73", "9000001.44^2^#{node}^1",
                   "9000001.44^3^#{node}^#{today}", "9000001.44^4^#{node}^#{DUZ}" ], filer_rows
    assert_sends_the_recorded_flow
  end

  # The same effective date with no source: EDIT, and the stored source is cleared.
  def test_add_mbi_clears_source_on_an_existing_row_when_source_is_omitted
    replay("mbi_existing")

    result = Reg.add_mbi(DFN, mbi: "1EG4TE5MK73", effective_date: MBI_EFFECTIVE)

    assert result[:success], result.inspect
    assert_equal "EDIT", filer_calls.first.last[0]
    assert_includes filer_rows, "9000001.44^2^3300601,#{DFN},^@"
    assert_sends_the_recorded_flow
  end

  def test_add_mbi_refuses_an_mbi_that_is_not_eleven_alphanumeric_characters
    replay

    assert_refused(Reg.add_mbi(DFN, mbi: "TOOSHORT", effective_date: MBI_EFFECTIVE), :invalid)
    assert_empty rpcs_sent
  end

  def test_add_mbi_refuses_when_the_client_has_no_duz
    @client = CapturedReplies::ReplayCiaClient.new({})
    RpmsRpc.configure { |cfg| cfg.client = @client }

    assert_refused(Reg.add_mbi(DFN, mbi: "1EG4TE5MK73", effective_date: MBI_EFFECTIVE), :invalid)
    assert_empty rpcs_sent
  end

  def test_mbis_lists_the_patients_mbi_rows
    replay("mbis")

    rows = Reg.mbis(DFN)

    assert_equal 1, rows.length
    assert_equal "1EG4TE5MK73", rows.first[:mbi]
    assert_equal MBI_EFFECTIVE, rows.first[:effective_date]
    assert_nil rows.first[:source]
    assert_sends_the_recorded_flow
  end

  # DDR GETS answers [ERROR] for a DFN with no #9000001 entry: it raises and
  # the subfile is not listed.
  def test_mbis_raises_when_the_9000001_entry_is_missing_and_does_not_list
    replay("mbis_no_patient")

    assert_raises(RpmsRpc::Client::RpcError) { Reg.mbis(NO_PATIENT) }
    assert_equal [ "DDR GETS ENTRY DATA" ], rpcs_sent
    assert_sends_the_recorded_flow
  end

  # -- set_sex -----------------------------------------------------------------

  # M to F with SSN verification on file: under AG's lock, the verification is
  # cleared, then the sex is filed; no eligibility row is on file to cascade.
  def test_set_sex_clears_ssn_verification_then_files_patient_sex_under_the_agg_lock
    replay("sex_change")

    result = Reg.set_sex(DFN, "F")

    assert result[:success], result.inspect
    assert_equal "AGG LOCK PATIENT", rpcs_sent.first
    assert_equal "AGG UNLOCK PATIENT", rpcs_sent.last
    assert_equal [ [ "EDIT", { 1 => "9000001^.23^#{DFN},^@" }, "", {} ],
                   [ "EDIT", { 1 => "2^.02^#{DFN},^F" }, "", {} ] ], filer_calls.map(&:last)
    assert_sends_the_recorded_flow
  end

  # Verification now blank: no SSN clear, the sex is still filed.
  def test_set_sex_skips_the_ssn_clear_when_verification_is_blank
    replay("sex_unchanged")

    result = Reg.set_sex(DFN, "  f  ")

    assert result[:success], result.inspect
    assert_equal [ [ "EDIT", { 1 => "2^.02^#{DFN},^F" }, "", {} ] ], filer_calls.map(&:last)
    assert_sends_the_recorded_flow
  end

  # AGG LOCK PATIENT answers -1 for a DFN no patient holds: no DDR call.
  def test_set_sex_returns_invalid_dfn_without_ddr_when_agg_lock_rejects_the_patient
    replay("sex_no_patient")

    result = Reg.set_sex(NO_PATIENT, "M")

    assert_refused(result, :invalid_dfn)
    assert_equal [ "AGG LOCK PATIENT" ], rpcs_sent
    assert_sends_the_recorded_flow
  end

  # Another user holds AG's lock: the build's refusal names them, and no DDR call runs.
  def test_set_sex_returns_lock_failed_without_ddr_when_another_user_holds_the_lock
    replay("sex_lock_held")

    result = Reg.set_sex(DFN, "M")

    assert_refused(result, :lock_failed)
    assert_equal [ "AGG LOCK PATIENT" ], rpcs_sent
    assert_sends_the_recorded_flow
  end

  def test_set_sex_refuses_an_invalid_dfn_or_sex_without_rpc
    [ [ "", "M" ], [ DFN, "male" ] ].each do |dfn, sex|
      replay

      assert_refused(Reg.set_sex(dfn, sex), :invalid)
      assert_empty rpcs_sent
    end
  end

  def test_set_sex_is_non_idempotent_write_in_retry_safety_yml
    table = YAML.load_file(RETRY_SAFETY_YML)
    assert_equal "non_idempotent_write", table.fetch("RpmsRpc::Registration.set_sex")
  end

  # -- not supported -----------------------------------------------------------

  def test_set_insurance_billing_order_sends_no_rpc_and_names_aupnicp
    replay

    result = Reg.set_insurance_billing_order(DFN, [ 1, 2 ])

    assert_refused(result, :not_supported)
    assert_match(/AUPNICP|\^AGCAT/i, result[:message])
    assert_empty rpcs_sent
  end

  def test_insurance_in_use_sends_no_rpc_and_names_used_agutils
    replay

    result = Reg.insurance_in_use(DFN)

    assert_refused(result, :not_supported)
    assert_match(/USED\^AGUTILS/i, result[:message])
    assert_empty rpcs_sent
  end
end
