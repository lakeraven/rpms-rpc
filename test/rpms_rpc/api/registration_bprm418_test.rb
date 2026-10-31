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
  GI_VALUE_IEN = 7
  SO_VALUE_IEN = 3
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

  def rpcs_sent
    @mock.received_calls.map { |c| c[:rpc] }
  end

  def seed_filer_add_ok
    @mock.seed(:ddr_filer, "ADD", "[Data]\n+1,^#{DFN}\n+2,^1\n+3,^2")
  end

  def fm(date) = FM.to_fileman(date)

  # -- set_gender_identity ----------------------------------------------------

  def test_set_gender_identity_files_9401_and_94011_through_ddr_filer_add
    seed_filer_add_ok
    row_fm = fm(ROW_DATE)

    result = Reg.set_gender_identity(DFN, values: [ GI_VALUE_IEN ], other: "self-described", date: ROW_DATE)

    assert result[:success]
    assert_equal 1, filer_calls.length
    call = filer_calls.first
    assert_equal "ADD", call[:params][0]
    assert_equal CONTEXT, call[:context]
    root = call[:params][1]
    assert_equal({ 1 => "9000001.9401^.01^+1,#{DFN},^#{row_fm}",
                   2 => "9000001.9401^2^+1,#{DFN},^self-described",
                   3 => "9000001.94011^.01^+2,+1,#{DFN},^#{GI_VALUE_IEN}" }, root)
    assert_equal({ 1 => row_fm }, call[:params][3])
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
    @mock.seed(:ddr_filer, "ADD",
               "[Data]\n[BEGIN_diERRORS]\n701^1^9000001.9401^+1,^.01^2\nThe value is not valid.\n[END_diERRORS]")

    result = Reg.set_gender_identity(DFN, values: [ GI_VALUE_IEN ], date: ROW_DATE)

    refute result[:success]
    assert_equal :filer_failed, result[:error]
    assert_includes result[:message].to_s, "not valid"
  end

  def test_set_gender_identity_returns_nil_when_ddr_filer_gives_no_response
    assert_nil Reg.set_gender_identity(DFN, values: [ GI_VALUE_IEN ], date: ROW_DATE)
  end

  # -- set_sexual_orientation -------------------------------------------------

  def test_set_sexual_orientation_files_9301_and_93011_through_ddr_filer_add
    seed_filer_add_ok
    row_fm = fm(ROW_DATE)

    result = Reg.set_sexual_orientation(DFN, values: [ SO_VALUE_IEN ], other: "note", date: ROW_DATE)

    assert result[:success]
    root = filer_calls.first[:params][1]
    assert_equal "9000001.9301^.01^+1,#{DFN},^#{row_fm}", root[1]
    assert_equal "9000001.93011^.01^+2,+1,#{DFN},^#{SO_VALUE_IEN}", root[3]
  end

  def test_set_sexual_orientation_refuses_blank_values_without_rpc
    result = Reg.set_sexual_orientation(DFN, values: [ nil ])

    refute result[:success]
    assert_equal :invalid, result[:error]
    assert_empty rpcs_sent
  end

  # -- set_legal_sex ----------------------------------------------------------

  def test_set_legal_sex_files_9201_with_dinum_date_sex_source_and_today_entered
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

  def test_set_legal_sex_refuses_an_invalid_sex_code_without_rpc
    result = Reg.set_legal_sex(DFN, sex: "U", source: LEGAL_SEX_SOURCE)

    refute result[:success]
    assert_equal :invalid, result[:error]
    assert_empty rpcs_sent
  end

  # -- add_mbi ----------------------------------------------------------------

  def test_add_mbi_files_9000001_44_with_upcased_mbi_and_signed_on_duz
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
