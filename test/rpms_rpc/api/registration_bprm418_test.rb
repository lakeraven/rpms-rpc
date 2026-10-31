# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/registration"

# Hermetic tests for rpms-rpc#418 registration rows: SOGI and MBI through DDR
# FILER/LISTER, and explicit not-supported surfaces for sex and insurance APIs
# that RPMS handles only through unreached M routines.
class RegistrationBprm418Test < Minitest::Test
  Reg = RpmsRpc::Registration
  Ddr = RpmsRpc::DdrFileman
  FM = RpmsRpc::FilemanDateParser

  DFN = 990_042
  CONTEXT = "CIAV VUECENTRIC"
  GI_CODE_FILE = "9999999.104"
  SO_CODE_FILE = "9999999.103"
  GI_OTHER_IEN = 6
  GI_VALUE_IEN = 7
  GI_EXTRA_VALUE_IEN = 3
  SO_VALUE_IEN = 3
  SO_EXTRA_VALUE_IEN = 5
  SO_OTHER_IEN = 4
  UNKNOWN_CODE_IEN = 424_242
  LEGAL_SEX_SOURCE = 1
  MBI = "1EG4TE5MK73"
  EFFECTIVE = Date.new(2026, 3, 15)
  ROW_DATE = Date.new(2026, 10, 15)

  def setup
    @mock = RpmsRpc.mock!
    @mock.instance_variable_set(:@session_duz, "501")
    @mock.define_singleton_method(:duz) { @session_duz }
    @mock.define_singleton_method(:clear_authenticated) { @session_duz = nil }
  end

  def teardown
    RpmsRpc.reset!
  end

  def filer_calls
    @mock.received_calls.select { |c| c[:rpc] == "DDR FILER" }
  end

  def lister_calls
    @mock.received_calls.select { |c| c[:rpc] == "DDR LISTER" }
  end

  def gets_calls
    @mock.received_calls.select { |c| c[:rpc] == "DDR GETS ENTRY DATA" }
  end

  def rpcs_sent
    @mock.received_calls.map { |c| c[:rpc] }
  end

  def fm(date) = FM.to_fileman(date)

  def seed_filer_add_ok
    @mock.seed(:ddr_filer, "ADD", "[Data]\n+1,^#{DFN}\n+2,^1\n+3,^2")
  end

  def seed_filer_edit_ok
    @mock.seed(:ddr_filer, "EDIT", "[Data]")
  end

  def seed_gets(file:, iens:, fields:, flags: "I", text:)
    key = Ddr.gets_entry_param(file: file, iens: iens, fields: fields, flags: flags).to_s
    @mock.seed(:ddr_gets_entry_data, key, text)
  end

  def assert_registration_failure(result, error:)
    assert_kind_of Hash, result, "expected a result Hash, got #{result.inspect}"
    refute result[:success]
    assert_equal error, result[:error]
  end

  def assert_registration_success(result)
    assert_kind_of Hash, result, "expected a result Hash, got #{result.inspect}"
    assert result[:success], result.inspect
  end

  def seed_code_field1(file, ien, internal)
    seed_gets(file: file, iens: "#{ien},", fields: "1", text: <<~REPLY.strip)
      [Data]
      #{file}^#{ien}^1^#{internal}^
    REPLY
  end

  def seed_code_field1_error(file, ien)
    seed_gets(file: file, iens: "#{ien},", fields: "1", text: "[ERROR]")
  end

  # Live DDR GETS still returns a row for an empty field; "[Data]" alone is malformed.
  def seed_code_field1_malformed_empty(file, ien)
    seed_gets(file: file, iens: "#{ien},", fields: "1", text: "[Data]")
  end

  def seed_sogi_codes(code_file, mapping)
    mapping.each { |ien, internal| seed_code_field1(code_file, ien, internal) }
  end

  def seed_default_gi_codes
    seed_sogi_codes(GI_CODE_FILE,
                    GI_VALUE_IEN => "ASKU",
                    GI_EXTRA_VALUE_IEN => "MALE",
                    GI_OTHER_IEN => "OTH")
  end

  def seed_default_so_codes
    seed_sogi_codes(SO_CODE_FILE,
                    SO_VALUE_IEN => "STR",
                    SO_EXTRA_VALUE_IEN => "QUEER",
                    SO_OTHER_IEN => "OTH")
  end

  def dated_row_lister_param(file:)
    Ddr.lister_param(file: file, iens: ",#{DFN},", fields: "@;.01I", flags: "IP")
  end

  def seed_dated_row_lister(file:, text:)
    key = dated_row_lister_param(file: file).to_s
    @mock.seed(:ddr_lister, key, text)
  end

  def seed_dated_row_exists(file:, row_fm:)
    seed_dated_row_lister(file: file, text: "[Data]\n#{row_fm}^#{row_fm}")
  end

  def seed_dated_row_missing(file:, row_fm:)
    seed_dated_row_lister(file: file, text: "[Data]")
  end

  def seed_dated_row_lister_failed(file:)
    seed_dated_row_lister(file: file, text: "[Data]\n[Errors]")
  end

  def assert_sogi_code_reads_then_dated_row_lister(file:, code_file:, code_iens:)
    code_iens = code_iens.uniq
    params = gets_calls.map { |c| c[:params].first }
    code_iens.each do |ien|
      assert_includes params, Ddr.gets_entry_param(file: code_file, iens: "#{ien},", fields: "1", flags: "I")
    end
    assert_equal code_iens.length, params.length, params.inspect
    assert_equal 1, lister_calls.length, lister_calls.inspect
    assert_equal dated_row_lister_param(file: file), lister_calls.first[:params].first
  end

  def assert_no_filer_or_lister
    assert_empty filer_calls, filer_calls.inspect
    assert_empty lister_calls, lister_calls.inspect
  end

  def assert_no_ddr_calls
    assert_no_filer_or_lister
    assert_empty gets_calls, gets_calls.inspect
  end

  def seed_sogi_value_lister(multiple:, row_fm:, entries:)
    key = Ddr.lister_param(file: multiple, iens: ",#{row_fm},#{DFN},", fields: ".01I", flags: "IP").to_s
    body = entries.map { |ien, code| "#{ien}^#{code}" }.join("\n")
    @mock.seed(:ddr_lister, key, "[Data]\n#{body}")
  end

  # -- set_gender_identity ----------------------------------------------------

  def test_set_gender_identity_files_9401_and_94011_through_ddr_filer_add_with_dinum_pins
    row_fm = fm(ROW_DATE)
    seed_default_gi_codes
    seed_dated_row_missing(file: "9000001.9401", row_fm: row_fm)
    seed_filer_add_ok

    result = Reg.set_gender_identity(DFN, values: [ GI_VALUE_IEN ], date: ROW_DATE)

    assert result[:success]
    assert_equal 1, filer_calls.length
    call = filer_calls.first
    assert_equal "ADD", call[:params][0]
    assert_equal CONTEXT, call[:context]
    root = call[:params][1]
    assert_equal({ 1 => "9000001.9401^.01^+1,#{DFN},^#{row_fm}",
                   2 => "9000001.9401^2^+1,#{DFN},^",
                   3 => "9000001.94011^.01^+2,+1,#{DFN},^#{GI_VALUE_IEN}" }, root)
    assert_equal({ 1 => row_fm, 2 => GI_VALUE_IEN.to_s }, call[:params][3])
    assert_sogi_code_reads_then_dated_row_lister(
      file: "9000001.9401", code_file: GI_CODE_FILE, code_iens: [ GI_VALUE_IEN ]
    )
  end

  def test_set_gender_identity_dinums_each_value_sub_entry_placeholder_to_its_code_ien
    row_fm = fm(ROW_DATE)
    seed_default_gi_codes
    seed_dated_row_missing(file: "9000001.9401", row_fm: row_fm)
    seed_filer_add_ok

    result = Reg.set_gender_identity(DFN, values: [ GI_VALUE_IEN, GI_EXTRA_VALUE_IEN ], date: ROW_DATE)

    assert result[:success]
    root = filer_calls.first[:params][1]
    assert_equal "9000001.9401^2^+1,#{DFN},^", root[2]
    assert_equal "9000001.94011^.01^+2,+1,#{DFN},^#{GI_VALUE_IEN}", root[3]
    assert_equal "9000001.94011^.01^+3,+1,#{DFN},^#{GI_EXTRA_VALUE_IEN}", root[4]
    assert_equal({ 1 => row_fm, 2 => GI_VALUE_IEN.to_s, 3 => GI_EXTRA_VALUE_IEN.to_s },
                 filer_calls.first[:params][3])
  end

  def test_set_gender_identity_files_duplicate_values_once
    row_fm = fm(ROW_DATE)
    seed_default_gi_codes
    seed_dated_row_missing(file: "9000001.9401", row_fm: row_fm)
    seed_filer_add_ok

    result = Reg.set_gender_identity(DFN, values: [ GI_VALUE_IEN, GI_VALUE_IEN ], date: ROW_DATE)

    assert result[:success]
    root = filer_calls.first[:params][1]
    assert_equal 3, root.length
    assert_equal({ 1 => row_fm, 2 => GI_VALUE_IEN.to_s }, filer_calls.first[:params][3])
  end

  def test_set_gender_identity_always_files_field_2_on_a_new_date
    row_fm = fm(ROW_DATE)
    seed_code_field1(GI_CODE_FILE, GI_OTHER_IEN, "OTH")
    seed_dated_row_missing(file: "9000001.9401", row_fm: row_fm)
    seed_filer_add_ok

    result = Reg.set_gender_identity(DFN, values: [ GI_OTHER_IEN ], other: "self-described", date: ROW_DATE)

    assert result[:success]
    root = filer_calls.first[:params][1]
    assert_equal "9000001.9401^2^+1,#{DFN},^self-described", root[2]
    assert_sogi_code_reads_then_dated_row_lister(
      file: "9000001.9401", code_file: GI_CODE_FILE, code_iens: [ GI_OTHER_IEN ]
    )
  end

  def test_set_gender_identity_files_empty_field_2_on_a_new_date_without_other_text
    row_fm = fm(ROW_DATE)
    seed_code_field1(GI_CODE_FILE, GI_VALUE_IEN, "ASKU")
    seed_dated_row_missing(file: "9000001.9401", row_fm: row_fm)
    seed_filer_add_ok

    result = Reg.set_gender_identity(DFN, values: [ GI_VALUE_IEN ], other: nil, date: ROW_DATE)

    assert result[:success]
    root = filer_calls.first[:params][1]
    assert_equal "9000001.9401^2^+1,#{DFN},^", root[2]
    assert_sogi_code_reads_then_dated_row_lister(
      file: "9000001.9401", code_file: GI_CODE_FILE, code_iens: [ GI_VALUE_IEN ]
    )
  end

  def test_set_gender_identity_refuses_other_text_when_no_chosen_value_is_the_other_code
    seed_code_field1(GI_CODE_FILE, GI_VALUE_IEN, "ASKU")

    result = Reg.set_gender_identity(DFN, values: [ GI_VALUE_IEN ], other: "self-described", date: ROW_DATE)

    assert_registration_failure(result, error: :invalid)
    assert_no_filer_or_lister
  end

  def test_set_gender_identity_refuses_an_unknown_code_ien_without_a_date_row_lookup
    seed_code_field1_error(GI_CODE_FILE, UNKNOWN_CODE_IEN)

    result = Reg.set_gender_identity(DFN, values: [ UNKNOWN_CODE_IEN ], date: ROW_DATE)

    assert_registration_failure(result, error: :invalid)
    assert_no_filer_or_lister
  end

  def test_set_gender_identity_returns_lookup_failed_when_a_value_code_read_gives_no_response
    result = Reg.set_gender_identity(DFN, values: [ GI_VALUE_IEN ], date: ROW_DATE)

    assert_registration_failure(result, error: :lookup_failed)
    assert_no_filer_or_lister
  end

  def test_set_gender_identity_returns_lookup_failed_when_a_value_code_read_omits_the_field_row
    seed_code_field1_malformed_empty(GI_CODE_FILE, GI_VALUE_IEN)

    result = Reg.set_gender_identity(DFN, values: [ GI_VALUE_IEN ], date: ROW_DATE)

    assert_registration_failure(result, error: :lookup_failed)
    assert_no_filer_or_lister
  end

  def test_set_gender_identity_returns_lookup_failed_when_other_gate_code_read_omits_the_field_row
    seed_code_field1_malformed_empty(GI_CODE_FILE, GI_OTHER_IEN)

    result = Reg.set_gender_identity(DFN, values: [ GI_OTHER_IEN ], other: "self-described", date: ROW_DATE)

    assert_registration_failure(result, error: :lookup_failed)
    assert_no_filer_or_lister
  end

  def test_set_gender_identity_refuses_when_a_value_code_read_returns_error
    seed_code_field1_error(GI_CODE_FILE, GI_VALUE_IEN)

    result = Reg.set_gender_identity(DFN, values: [ GI_VALUE_IEN ], date: ROW_DATE)

    assert_registration_failure(result, error: :invalid)
    assert_no_filer_or_lister
  end

  def test_set_gender_identity_refuses_when_other_gate_code_read_returns_error
    seed_code_field1_error(GI_CODE_FILE, GI_OTHER_IEN)

    result = Reg.set_gender_identity(DFN, values: [ GI_OTHER_IEN ], other: "self-described", date: ROW_DATE)

    assert_registration_failure(result, error: :invalid)
    assert_no_filer_or_lister
  end

  def test_set_gender_identity_returns_lookup_failed_when_other_code_read_gives_no_response
    result = Reg.set_gender_identity(DFN, values: [ GI_OTHER_IEN ], other: "self-described", date: ROW_DATE)

    assert_registration_failure(result, error: :lookup_failed)
    assert_no_filer_or_lister
  end

  def test_set_gender_identity_clears_other_text_on_an_existing_date_without_an_oth_value
    row_fm = fm(ROW_DATE)
    seed_default_gi_codes
    seed_dated_row_exists(file: "9000001.9401", row_fm: row_fm)
    seed_sogi_value_lister(multiple: "9000001.94011", row_fm: row_fm, entries: [ [ GI_OTHER_IEN, GI_OTHER_IEN ] ])
    seed_filer_add_ok

    result = Reg.set_gender_identity(DFN, values: [ GI_VALUE_IEN ], date: ROW_DATE)

    assert_registration_success(result)
    root = filer_calls.first[:params][1]
    assert_includes root.values, "9000001.9401^2^#{row_fm},#{DFN},^"
    assert_includes root.values, "9000001.94011^.01^#{GI_OTHER_IEN},#{row_fm},#{DFN},^@"
  end

  def test_set_gender_identity_edits_an_existing_date_row_and_reconciles_value_sub_entries
    row_fm = fm(ROW_DATE)
    seed_default_gi_codes
    seed_dated_row_exists(file: "9000001.9401", row_fm: row_fm)
    seed_sogi_value_lister(multiple: "9000001.94011", row_fm: row_fm, entries: [ [ 5, 5 ], [ 7, 7 ] ])
    seed_filer_add_ok
    seed_filer_edit_ok

    result = Reg.set_gender_identity(DFN, values: [ GI_VALUE_IEN, GI_EXTRA_VALUE_IEN ], date: ROW_DATE)

    assert_registration_success(result)
    assert_equal 1, filer_calls.length, filer_calls.inspect
    add = filer_calls.first
    assert_equal "ADD", add[:params][0]
    root = add[:params][1]
    assert_equal "9000001.9401^.01^#{row_fm},#{DFN},^#{row_fm}", root[1]
    assert_includes root.values, "9000001.9401^2^#{row_fm},#{DFN},^"
    assert_includes root.values, "9000001.94011^.01^5,#{row_fm},#{DFN},^@"
    assert_includes root.values, "9000001.94011^.01^+2,#{row_fm},#{DFN},^#{GI_EXTRA_VALUE_IEN}"
    refute_includes root.values, "9000001.94011^.01^+2,#{row_fm},#{DFN},^#{GI_VALUE_IEN}"
    assert_equal({ 2 => GI_EXTRA_VALUE_IEN.to_s }, add[:params][3])
    refute_includes root.values.join("^"), "+1,#{DFN},"
  end

  def test_set_gender_identity_returns_lookup_failed_when_the_date_row_read_fails
    seed_code_field1(GI_CODE_FILE, GI_VALUE_IEN, "ASKU")
    seed_dated_row_lister_failed(file: "9000001.9401")

    result = Reg.set_gender_identity(DFN, values: [ GI_VALUE_IEN ], date: ROW_DATE)

    assert_registration_failure(result, error: :lookup_failed)
    assert_empty filer_calls
  end

  def test_set_gender_identity_returns_lookup_failed_when_the_existing_value_list_read_fails
    row_fm = fm(ROW_DATE)
    seed_code_field1(GI_CODE_FILE, GI_VALUE_IEN, "ASKU")
    seed_dated_row_exists(file: "9000001.9401", row_fm: row_fm)
    key = Ddr.lister_param(file: "9000001.94011", iens: ",#{row_fm},#{DFN},", fields: ".01I", flags: "IP").to_s
    @mock.seed(:ddr_lister, key, "[Data]\n[Errors]")

    result = Reg.set_gender_identity(DFN, values: [ GI_VALUE_IEN ], date: ROW_DATE)

    assert_registration_failure(result, error: :lookup_failed)
    assert_empty filer_calls
  end

  def test_set_gender_identity_refuses_blank_dfn_without_rpc
    result = Reg.set_gender_identity("", values: [ 1 ])

    refute result[:success]
    assert_equal :invalid, result[:error]
    assert_empty rpcs_sent
  end

  def test_set_gender_identity_refuses_empty_values_without_rpc
    result = Reg.set_gender_identity(DFN, values: [])

    refute result[:success]
    assert_equal :invalid, result[:error]
    assert_empty rpcs_sent
  end

  def test_set_gender_identity_refuses_non_integer_values_without_rpc
    result = Reg.set_gender_identity(DFN, values: [ "7" ])

    refute result[:success]
    assert_equal :invalid, result[:error]
    assert_empty rpcs_sent
  end

  def test_set_gender_identity_surfaces_ddr_filer_errors
    seed_code_field1(GI_CODE_FILE, GI_VALUE_IEN, "ASKU")
    seed_dated_row_missing(file: "9000001.9401", row_fm: fm(ROW_DATE))
    @mock.seed(:ddr_filer, "ADD",
               "[Data]\n[BEGIN_diERRORS]\n701^1^9000001.9401^+1,^.01^2\nThe value is not valid.\n[END_diERRORS]")

    result = Reg.set_gender_identity(DFN, values: [ GI_VALUE_IEN ], date: ROW_DATE)

    refute result[:success]
    assert_equal :filer_failed, result[:error]
    assert_includes result[:message].to_s, "not valid"
  end

  def test_set_gender_identity_returns_nil_when_ddr_filer_gives_no_response
    seed_code_field1(GI_CODE_FILE, GI_VALUE_IEN, "ASKU")
    seed_dated_row_missing(file: "9000001.9401", row_fm: fm(ROW_DATE))
    assert_nil Reg.set_gender_identity(DFN, values: [ GI_VALUE_IEN ], date: ROW_DATE)
  end

  # -- set_sexual_orientation -------------------------------------------------

  def test_set_sexual_orientation_files_9301_and_93011_through_ddr_filer_add_with_dinum_pins
    row_fm = fm(ROW_DATE)
    seed_default_so_codes
    seed_dated_row_missing(file: "9000001.9301", row_fm: row_fm)
    seed_filer_add_ok

    result = Reg.set_sexual_orientation(DFN, values: [ SO_VALUE_IEN ], date: ROW_DATE)

    assert result[:success]
    root = filer_calls.first[:params][1]
    assert_equal "9000001.9301^.01^+1,#{DFN},^#{row_fm}", root[1]
    assert_equal "9000001.9301^2^+1,#{DFN},^", root[2]
    assert_equal "9000001.93011^.01^+2,+1,#{DFN},^#{SO_VALUE_IEN}", root[3]
    assert_equal({ 1 => row_fm, 2 => SO_VALUE_IEN.to_s }, filer_calls.first[:params][3])
  end

  def test_set_sexual_orientation_always_files_field_2_on_a_new_date
    seed_code_field1(SO_CODE_FILE, SO_OTHER_IEN, "OTH")
    seed_dated_row_missing(file: "9000001.9301", row_fm: fm(ROW_DATE))
    seed_filer_add_ok

    result = Reg.set_sexual_orientation(DFN, values: [ SO_OTHER_IEN ], other: "note", date: ROW_DATE)

    assert result[:success]
    assert_equal "9000001.9301^2^+1,#{DFN},^note", filer_calls.first[:params][1][2]
    assert_sogi_code_reads_then_dated_row_lister(
      file: "9000001.9301", code_file: SO_CODE_FILE, code_iens: [ SO_OTHER_IEN ]
    )
  end

  def test_set_sexual_orientation_refuses_other_text_when_no_chosen_value_is_the_other_code
    seed_code_field1(SO_CODE_FILE, SO_VALUE_IEN, "STR")

    result = Reg.set_sexual_orientation(DFN, values: [ SO_VALUE_IEN ], other: "note", date: ROW_DATE)

    assert_registration_failure(result, error: :invalid)
    assert_no_filer_or_lister
  end

  def test_set_sexual_orientation_refuses_an_unknown_code_ien_without_a_date_row_lookup
    seed_code_field1_error(SO_CODE_FILE, UNKNOWN_CODE_IEN)

    result = Reg.set_sexual_orientation(DFN, values: [ UNKNOWN_CODE_IEN ], date: ROW_DATE)

    assert_registration_failure(result, error: :invalid)
    assert_no_filer_or_lister
  end

  def test_set_sexual_orientation_returns_lookup_failed_when_a_value_code_read_omits_the_field_row
    seed_code_field1_malformed_empty(SO_CODE_FILE, SO_VALUE_IEN)

    result = Reg.set_sexual_orientation(DFN, values: [ SO_VALUE_IEN ], date: ROW_DATE)

    assert_registration_failure(result, error: :lookup_failed)
    assert_no_filer_or_lister
  end

  def test_set_sexual_orientation_returns_lookup_failed_when_other_gate_code_read_omits_the_field_row
    seed_code_field1_malformed_empty(SO_CODE_FILE, SO_OTHER_IEN)

    result = Reg.set_sexual_orientation(DFN, values: [ SO_OTHER_IEN ], other: "note", date: ROW_DATE)

    assert_registration_failure(result, error: :lookup_failed)
    assert_no_filer_or_lister
  end

  def test_set_sexual_orientation_refuses_blank_values_without_rpc
    result = Reg.set_sexual_orientation(DFN, values: [ nil ])

    refute result[:success]
    assert_equal :invalid, result[:error]
    assert_empty rpcs_sent
  end

  def test_set_sexual_orientation_updates_an_existing_date_row_and_reconciles_value_sub_entries
    row_fm = fm(ROW_DATE)
    seed_default_so_codes
    seed_dated_row_exists(file: "9000001.9301", row_fm: row_fm)
    seed_sogi_value_lister(multiple: "9000001.93011", row_fm: row_fm, entries: [ [ 2, 2 ], [ 3, 3 ] ])
    seed_filer_add_ok
    seed_filer_edit_ok

    result = Reg.set_sexual_orientation(DFN, values: [ SO_VALUE_IEN, SO_EXTRA_VALUE_IEN ], date: ROW_DATE)

    assert_registration_success(result)
    assert_equal 1, filer_calls.length, filer_calls.inspect
    add = filer_calls.first
    assert_equal "ADD", add[:params][0]
    root = add[:params][1]
    assert_equal "9000001.9301^.01^#{row_fm},#{DFN},^#{row_fm}", root[1]
    assert_includes root.values, "9000001.9301^2^#{row_fm},#{DFN},^"
    assert_includes root.values, "9000001.93011^.01^2,#{row_fm},#{DFN},^@"
    assert_includes root.values, "9000001.93011^.01^+2,#{row_fm},#{DFN},^#{SO_EXTRA_VALUE_IEN}"
    refute_includes root.values, "9000001.93011^.01^+2,#{row_fm},#{DFN},^#{SO_VALUE_IEN}"
    assert_equal({ 2 => SO_EXTRA_VALUE_IEN.to_s }, add[:params][3])
    refute_includes root.values.join("^"), "+1,#{DFN},"
  end

  # -- set_legal_sex ----------------------------------------------------------

  def test_set_legal_sex_files_9201_with_dinum_date_sex_source_and_today_entered
    seed_dated_row_missing(file: "9000001.9201", row_fm: fm(ROW_DATE))
    seed_filer_add_ok
    row_fm = fm(ROW_DATE)
    today_fm = fm(Date.today)

    result = Reg.set_legal_sex(DFN, sex: "X", source: LEGAL_SEX_SOURCE, date: ROW_DATE)

    assert result[:success]
    root = filer_calls.first[:params][1]
    assert_equal({ 1 => "9000001.9201^.01^+1,#{DFN},^#{row_fm}",
                   2 => "9000001.9201^1^+1,#{DFN},^X",
                   3 => "9000001.9201^2^+1,#{DFN},^#{LEGAL_SEX_SOURCE}",
                   4 => "9000001.9201^3^+1,#{DFN},^#{today_fm}" }, root)
    assert_equal({ 1 => row_fm }, filer_calls.first[:params][3])
  end

  def test_set_legal_sex_edits_an_existing_date_row_in_edit_mode
    row_fm = fm(ROW_DATE)
    seed_dated_row_exists(file: "9000001.9201", row_fm: row_fm)
    seed_filer_edit_ok

    result = Reg.set_legal_sex(DFN, sex: "F", source: LEGAL_SEX_SOURCE, date: ROW_DATE)

    assert_registration_success(result)
    refute_empty filer_calls, "expected a DDR FILER call"
    edit = filer_calls.first
    assert_equal "EDIT", edit[:params][0]
    root = edit[:params][1]
    assert_equal "9000001.9201^.01^#{row_fm},#{DFN},^#{row_fm}", root[1]
    assert_equal "9000001.9201^1^#{row_fm},#{DFN},^F", root[2]
    assert_empty edit[:params][3]
    refute_includes root.values.join("^"), "+1,#{DFN},"
  end

  def test_set_legal_sex_returns_lookup_failed_when_the_date_row_read_fails
    seed_dated_row_lister_failed(file: "9000001.9201")

    result = Reg.set_legal_sex(DFN, sex: "X", source: LEGAL_SEX_SOURCE, date: ROW_DATE)

    assert_registration_failure(result, error: :lookup_failed)
    assert_empty filer_calls
  end

  def test_set_legal_sex_refuses_an_invalid_sex_code_without_rpc
    result = Reg.set_legal_sex(DFN, sex: "U", source: LEGAL_SEX_SOURCE)

    refute result[:success]
    assert_equal :invalid, result[:error]
    assert_empty rpcs_sent
  end

  # -- add_mbi ----------------------------------------------------------------

  def test_add_mbi_files_9000001_44_with_upcased_mbi_and_signed_on_duz
    seed_dated_row_missing(file: "9000001.44", row_fm: fm(EFFECTIVE))
    seed_filer_add_ok
    eff_fm = fm(EFFECTIVE)
    today_fm = fm(Date.today)

    result = Reg.add_mbi(DFN, mbi: "1eg4te5mk73", effective_date: EFFECTIVE, source: 2)

    assert result[:success]
    root = filer_calls.first[:params][1]
    assert_equal MBI, root[2].split("^", -1).last
    assert_includes root.values.join("^"), "^#{eff_fm}^"
    assert_equal "9000001.44^4^+1,#{DFN},^501", root[5]
    assert_equal "9000001.44^3^+1,#{DFN},^#{today_fm}", root[4]
    assert_equal({ 1 => eff_fm }, filer_calls.first[:params][3])
  end

  def test_add_mbi_edits_an_existing_effective_date_row_in_edit_mode
    eff_fm = fm(EFFECTIVE)
    seed_dated_row_exists(file: "9000001.44", row_fm: eff_fm)
    seed_filer_edit_ok

    result = Reg.add_mbi(DFN, mbi: MBI, effective_date: EFFECTIVE, source: 2)

    assert_registration_success(result)
    refute_empty filer_calls, "expected a DDR FILER call"
    edit = filer_calls.first
    assert_equal "EDIT", edit[:params][0]
    root = edit[:params][1]
    assert_equal "9000001.44^.01^#{eff_fm},#{DFN},^#{eff_fm}", root[1]
    assert_equal "9000001.44^1^#{eff_fm},#{DFN},^#{MBI}", root[2]
    assert_equal "9000001.44^2^#{eff_fm},#{DFN},^2", root[3]
    refute_includes root.values.join("^"), "+1,#{DFN},"
  end

  def test_add_mbi_clears_source_on_an_existing_row_when_source_is_omitted
    eff_fm = fm(EFFECTIVE)
    seed_dated_row_exists(file: "9000001.44", row_fm: eff_fm)
    seed_filer_edit_ok
    today_fm = fm(Date.today)

    result = Reg.add_mbi(DFN, mbi: MBI, effective_date: EFFECTIVE)

    assert_registration_success(result)
    edit = filer_calls.first
    assert_equal "EDIT", edit[:params][0]
    root = edit[:params][1]
    assert_equal "9000001.44^2^#{eff_fm},#{DFN},^@", root[3]
    assert_equal "9000001.44^3^#{eff_fm},#{DFN},^#{today_fm}", root[4]
    assert_equal "9000001.44^4^#{eff_fm},#{DFN},^501", root[5]
  end

  def test_add_mbi_returns_lookup_failed_when_the_effective_date_row_read_fails
    seed_dated_row_lister_failed(file: "9000001.44")

    result = Reg.add_mbi(DFN, mbi: MBI, effective_date: EFFECTIVE)

    assert_registration_failure(result, error: :lookup_failed)
    assert_empty filer_calls
  end

  def test_add_mbi_refuses_an_mbi_that_is_not_eleven_alphanumeric_characters
    result = Reg.add_mbi(DFN, mbi: "TOOSHORT", effective_date: EFFECTIVE)

    refute result[:success]
    assert_equal :invalid, result[:error]
    assert_empty rpcs_sent
  end

  def test_add_mbi_refuses_when_the_client_has_no_duz
    RpmsRpc.client.clear_authenticated

    result = Reg.add_mbi(DFN, mbi: MBI, effective_date: EFFECTIVE)

    refute result[:success]
    assert_equal :invalid, result[:error]
    assert_empty rpcs_sent
  end

  # -- mbis -------------------------------------------------------------------

  def test_mbis_reads_9000001_44_through_ddr_lister_for_the_patient
    key = Ddr.lister_param(file: "9000001.44", iens: ",#{DFN},", fields: ".01I;1;2I", flags: "IP").to_s
    @mock.seed(:ddr_lister, key, "[Data]\n1^#{fm(EFFECTIVE)}^#{MBI}^2")

    rows = Reg.mbis(DFN)

    assert_equal [ { effective_date: EFFECTIVE, mbi: MBI, source: 2 } ], rows
    assert_equal 1, lister_calls.length
    assert_equal CONTEXT, lister_calls.first[:context]
  end

  def test_mbis_raises_when_a_listed_row_has_a_blank_mbi_field
    key = Ddr.lister_param(file: "9000001.44", iens: ",#{DFN},", fields: ".01I;1;2I", flags: "IP").to_s
    @mock.seed(:ddr_lister, key, "[Data]\n3^3260315^^2")

    assert_raises(RpmsRpc::Client::RpcError) { Reg.mbis(DFN) }
  end

  def test_mbis_raises_when_the_ddr_read_fails
    key = Ddr.lister_param(file: "9000001.44", iens: ",#{DFN},", fields: ".01I;1;2I", flags: "IP").to_s
    @mock.seed(:ddr_lister, key, "[Data]\n[Errors]")

    assert_raises(RpmsRpc::Client::RpcError) { Reg.mbis(DFN) }
  end

  # -- not supported ----------------------------------------------------------

  def test_set_sex_sends_no_rpc_and_names_sexelig_agutl
    result = Reg.set_sex(DFN, "M")

    refute result[:success]
    assert_equal :not_supported, result[:error]
    assert_match(/SEXELIG\^AGUTL/i, result[:message])
    assert_match(/done in RPMS/i, result[:message])
    assert_empty rpcs_sent
  end

  def test_set_insurance_billing_order_sends_no_rpc_and_names_aupnicp
    result = Reg.set_insurance_billing_order(DFN, [ 1, 2 ])

    refute result[:success]
    assert_equal :not_supported, result[:error]
    assert_match(/AUPNICP|\^AGCAT/i, result[:message])
    assert_empty rpcs_sent
  end

  def test_insurance_in_use_sends_no_rpc_and_names_used_agutils
    result = Reg.insurance_in_use(DFN)

    refute result[:success]
    assert_equal :not_supported, result[:error]
    assert_match(/USED\^AGUTILS/i, result[:message])
    assert_empty rpcs_sent
  end
end
