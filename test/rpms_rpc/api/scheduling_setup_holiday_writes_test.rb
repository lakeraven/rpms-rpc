# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/scheduling_setup"
require_relative "../captured_replies"

# rpms-rpc#418 scheduling setup rows: HOLIDAY (#40.5) add through DDR FILER
# ADD and remove by B-xref lookup then EDIT .01 "@". The replies are the
# build's (test/fixtures/captured_replies/scheduling-holiday-writes.yml): the
# writes run as PROFILE,MD on a throwaway container, recorded as flows and
# replayed through CiaClient. Each test that reaches the wire checks the gem
# sent exactly the recorded calls.
class SchedulingSetupHolidayWritesTest < Minitest::Test
  Setup = RpmsRpc::SchedulingSetup
  CONTEXT = "CIAV VUECENTRIC"

  SLUG = "scheduling-holiday-writes"

  HOLIDAY_DATE = Date.new(2031, 7, 4)
  NAME = "LIVESPEC INDEPENDENCE"

  def setup
    replay
  end

  def teardown
    RpmsRpc.reset!
  end

  def fm(date) = RpmsRpc::FilemanDateParser.to_fileman(date)

  # A client with no replies unless a flow is named: a test that reaches the
  # wire without one fails.
  def replay(script = {})
    @client = CapturedReplies::ReplayCiaClient.new(script)
    RpmsRpc.configure { |cfg| cfg.client = @client }
  end

  def replay_flow(name) = replay(CapturedReplies.flow_script(SLUG, name))

  def sent = @client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params] ] }

  def filer_calls = @client.calls.select { |c| c[:rpc] == "DDR FILER" }

  def lister_calls = @client.calls.select { |c| c[:rpc] == "DDR LISTER" }

  def test_add_holiday_files_40_5_date_and_name_through_ddr_filer_add
    replay_flow("add")

    result = Setup.add_holiday(date: HOLIDAY_DATE, name: NAME)

    assert result[:success]
    call = filer_calls.first
    assert_equal CapturedReplies.flow_calls(SLUG, "add"), sent
    assert_equal CONTEXT, @client.current_context
    assert_equal({ 1 => "40.5^.01^+1,^#{fm(HOLIDAY_DATE)}",
                   2 => "40.5^2^+1,^#{NAME}" }, call[:params][1])
    assert_equal({ 1 => fm(HOLIDAY_DATE) }, call[:params][3])
  end

  def test_add_holiday_refuses_a_blank_name_without_rpc
    result = Setup.add_holiday(date: HOLIDAY_DATE, name: "   ")

    refute result[:success]
    assert_equal :invalid, result[:error]
    assert_empty @client.calls
  end

  def test_add_holiday_refuses_a_name_over_thirty_characters_without_rpc
    result = Setup.add_holiday(date: HOLIDAY_DATE, name: "X" * 31)

    refute result[:success]
    assert_equal :invalid, result[:error]
    assert_empty @client.calls
  end

  def test_add_holiday_refuses_name_with_caret_without_rpc
    result = Setup.add_holiday(date: HOLIDAY_DATE, name: "FOUR^TH")

    assert_equal :invalid, result&.dig(:error), result.inspect
    refute result[:success]
    assert_empty @client.calls
  end

  def test_add_holiday_refuses_name_at_sign_without_rpc
    result = Setup.add_holiday(date: HOLIDAY_DATE, name: "@")

    assert_equal :invalid, result&.dig(:error), result.inspect
    refute result[:success]
    assert_empty @client.calls
  end

  def test_add_holiday_refuses_name_with_control_byte_without_rpc
    result = Setup.add_holiday(date: HOLIDAY_DATE, name: "LABOR\x01DAY")

    assert_equal :invalid, result&.dig(:error), result.inspect
    refute result[:success]
    assert_empty @client.calls
  end

  # The date is already on file: FileMan answers error 302, "Entry
  # '3310704,' already exists."
  def test_add_holiday_surfaces_ddr_filer_errors
    replay_flow("add_again")

    result = Setup.add_holiday(date: HOLIDAY_DATE, name: NAME)

    refute result[:success]
    assert_equal :filer_failed, result[:error]
    assert_equal CapturedReplies.flow_calls(SLUG, "add_again"), sent
  end

  def test_remove_holiday_edits_the_b_xref_entry_to_delete
    replay_flow("remove")

    result = Setup.remove_holiday(HOLIDAY_DATE)

    assert result[:success]
    assert_equal CapturedReplies.flow_calls(SLUG, "remove"), sent
    assert_equal 1, lister_calls.length
    assert_equal "B", lister_calls.first[:params].first["XREF"]
    edit = filer_calls.first
    assert_equal "EDIT", edit[:params][0]
    assert_equal({ 1 => "40.5^.01^#{fm(HOLIDAY_DATE)},^@" }, edit[:params][1])
  end

  # 2031-12-26: no holiday on file from that date on, so the lister answers
  # "[Data]" with no rows.
  def test_remove_holiday_returns_not_found_when_no_entry_exists_for_the_date
    replay_flow("remove_none_after")

    result = Setup.remove_holiday(Date.new(2031, 12, 26))

    refute result[:success]
    assert_equal :not_found, result[:error]
    assert_equal CapturedReplies.flow_calls(SLUG, "remove_none_after"), sent
    assert_empty filer_calls
  end

  # 2031-07-04 is gone; the next holiday on file is 2031-12-25.
  def test_remove_holiday_returns_not_found_when_lister_returns_only_a_later_holiday
    replay_flow("remove_again")

    result = Setup.remove_holiday(HOLIDAY_DATE)

    refute result[:success]
    assert_equal :not_found, result[:error]
    assert_equal CapturedReplies.flow_calls(SLUG, "remove_again"), sent
    assert_empty filer_calls
    assert_equal (fm(HOLIDAY_DATE).to_i - 1).to_s, lister_calls.first[:params].first["FROM"]
  end
end
