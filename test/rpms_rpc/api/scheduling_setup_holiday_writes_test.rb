# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/scheduling_setup"

# rpms-rpc#418 scheduling setup rows: HOLIDAY (#40.5) add through DDR FILER
# ADD and remove by B-xref lookup then EDIT .01 "@".
class SchedulingSetupHolidayWritesTest < Minitest::Test
  Setup = RpmsRpc::SchedulingSetup
  Ddr = RpmsRpc::DdrFileman
  CONTEXT = "CIAV VUECENTRIC"

  HOLIDAY_DATE = Date.new(2031, 7, 4)
  NAME = "LIVESPEC INDEPENDENCE"

  def setup
    @mock = RpmsRpc.mock!
  end

  def teardown
    RpmsRpc.reset!
  end

  def fm(date) = RpmsRpc::FilemanDateParser.to_fileman(date)

  def filer_calls
    @mock.received_calls.select { |c| c[:rpc] == "DDR FILER" }
  end

  def lister_calls
    @mock.received_calls.select { |c| c[:rpc] == "DDR LISTER" }
  end

  def remove_holiday_lister_key(date = HOLIDAY_DATE)
    Ddr.lister_param(file: "40.5", fields: "@;.01I", flags: "IP", max: 1, xref: "B",
                     from: (fm(date).to_i - 1).to_s).to_s
  end

  def test_add_holiday_files_40_5_date_and_name_through_ddr_filer_add
    @mock.seed(:ddr_filer, "ADD", "[Data]\n+1,^99")

    result = Setup.add_holiday(date: HOLIDAY_DATE, name: NAME)

    assert result[:success]
    call = filer_calls.first
    assert_equal CONTEXT, call[:context]
    assert_equal({ 1 => "40.5^.01^+1,^#{fm(HOLIDAY_DATE)}",
                   2 => "40.5^2^+1,^#{NAME}" }, call[:params][1])
    assert_equal({ 1 => fm(HOLIDAY_DATE) }, call[:params][3])
  end

  def test_add_holiday_refuses_a_blank_name_without_rpc
    result = Setup.add_holiday(date: HOLIDAY_DATE, name: "   ")

    refute result[:success]
    assert_equal :invalid, result[:error]
    assert_empty @mock.received_calls
  end

  def test_add_holiday_refuses_a_name_over_thirty_characters_without_rpc
    result = Setup.add_holiday(date: HOLIDAY_DATE, name: "X" * 31)

    refute result[:success]
    assert_equal :invalid, result[:error]
    assert_empty @mock.received_calls
  end

  def test_add_holiday_surfaces_ddr_filer_errors
    @mock.seed(:ddr_filer, "ADD",
               "[Data]\n[BEGIN_diERRORS]\n701^1^40.5^+1,^.01^2\nDuplicate.\n[END_diERRORS]")

    result = Setup.add_holiday(date: HOLIDAY_DATE, name: NAME)

    refute result[:success]
    assert_equal :filer_failed, result[:error]
  end

  def test_add_holiday_returns_nil_when_ddr_filer_gives_no_response
    assert_nil Setup.add_holiday(date: HOLIDAY_DATE, name: NAME)
  end

  def test_remove_holiday_edits_the_b_xref_entry_to_delete
    @mock.seed(:ddr_lister, remove_holiday_lister_key, "[Data]\n12^#{fm(HOLIDAY_DATE)}^#{NAME}")
    @mock.seed(:ddr_filer, "EDIT", "[Data]")

    result = Setup.remove_holiday(HOLIDAY_DATE)

    assert result[:success]
    assert_equal 1, lister_calls.length
    assert_equal "B", lister_calls.first[:params]["XREF"]
    edit = filer_calls.first
    assert_equal "EDIT", edit[:params][0]
    assert_equal({ 1 => "40.5^.01^12,^@" }, edit[:params][1])
  end

  def test_remove_holiday_returns_not_found_when_no_entry_exists_for_the_date
    @mock.seed(:ddr_lister, remove_holiday_lister_key, "[Data]")

    result = Setup.remove_holiday(HOLIDAY_DATE)

    refute result[:success]
    assert_equal :not_found, result[:error]
    assert_empty filer_calls
  end

  def test_remove_holiday_returns_not_found_when_lister_returns_only_a_later_holiday
    later = Date.new(2031, 12, 25)
    @mock.seed(:ddr_lister, remove_holiday_lister_key, "[Data]\n99^#{fm(later)}^CHRISTMAS")

    result = Setup.remove_holiday(HOLIDAY_DATE)

    refute result[:success]
    assert_equal :not_found, result[:error]
    assert_empty filer_calls
    assert_equal (fm(HOLIDAY_DATE).to_i - 1).to_s, lister_calls.first[:params]["FROM"]
    assert_equal "B", lister_calls.first[:params]["XREF"]
  end
end
