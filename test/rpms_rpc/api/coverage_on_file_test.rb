# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/coverage"
require_relative "../captured_replies"

# Coverage.on_file reads a patient's coverage through AG's own window RPCs,
# and add_medicaid / add_medicare / add_private_insurance file what the front
# desk records (rpms-ux S-REG-03.1).
#
# The replies are the build's (test/fixtures/captured_replies/coverage-on-file.yml):
# each call run on a throwaway container as PROFILE,REG on demo patient 990049,
# recorded as a flow and replayed through CiaClient. The round trip, with
# FileMan confirming each value, is test/live/coverage_on_file_live_test.rb.
#
# Not captured, so not tested here: a refusal from UPD^AGGUPPVT (the build
# filed every policy it was sent, even one naming no insurer on file), a window
# that answers a blank Medicare row, and a window read with no typed reply.
# Those were tested against replies written by hand, which ADR 0009 retires.
class CoverageOnFileTest < Minitest::Test
  SLUG = "coverage-on-file"
  Cov = RpmsRpc::Coverage
  FS = "\x1c"
  DFN = 990_049
  WASHINGTON = "48" # STATE WASHINGTON on the pinned build, as the add_medicaid flow found it

  def teardown
    RpmsRpc.reset!
  end

  def replay(script = {})
    client = CapturedReplies::ReplayCiaClient.new(script)
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def replay_flow(name) = replay(CapturedReplies.flow_script(SLUG, name))

  # The RPCs the gem sent, with the context bound when each went out.
  def wire(client)
    context = CapturedReplies::ReplayCiaClient::SIGNON_CONTEXT
    client.calls.filter_map do |c|
      next (context = c[:params].first) && nil if c[:rpc] == :create_context

      [ c[:rpc], c[:params], context ]
    end
  end

  # Replies are chosen by RPC name, so this is what checks each call's
  # parameters: the gem sent exactly what the build answered in that flow.
  def assert_sent_the_flow(client, name)
    assert_equal CapturedReplies.flow_calls(SLUG, name), wire(client).map { |rpc, params, _| [ rpc, params ] }
  end

  def test_s_reg_03_1_on_file_reads_each_payer_with_number_dates_and_whether_it_is_in_force
    client = replay_flow("on_file")
    got = Cov.on_file(DFN)
    assert_sent_the_flow(client, "on_file")

    lapsed, current = got[:medicaid].partition { |e| e[:number] == "ZZ49LAPSE" }.map(&:first)
    assert_equal [ "MEDICAID", "ZZ4900001", "WASHINGTON", true ], current.values_at(:payer, :number, :state, :active)
    assert_equal({ ien: "3260101", starts_on: Date.new(2026, 1, 1), ends_on: Date.new(2027, 12, 31), coverage: "" },
                 current[:eligibility].first)
    assert_equal false, lapsed[:active], "AG reads an eligibility that ended 06/30/2025 as not in force"
    assert_equal Date.new(2025, 6, 30), lapsed[:eligibility].first[:ends_on]

    medicare = got[:medicare].first
    assert_equal [ "MEDICARE", "1EG4TE5MK73", true ], medicare.values_at(:payer, :number, :active)
    assert_equal "PART B", medicare[:eligibility].first[:coverage]

    policy = got[:private].first
    assert_equal [ "VETERANS MEDICAL BENEFIT", "5", "ZZM49", "ZEPHYR,QUINN", true ],
                 policy.values_at(:payer, :payer_ien, :number, :policy_holder, :active)
    assert_equal [ Date.new(2026, 1, 1), Date.new(2027, 12, 31) ], policy.values_at(:starts_on, :ends_on),
                 "the member's own dates, not AG's display, which blanks an end date still to come"

    agg_calls = wire(client).reject { |rpc, _, _| rpc.start_with?("DDR") }
    assert(agg_calls.all? { |_, _, context| context == "AGGRPC" }, "every window read runs in AGGRPC")
  end

  def test_on_file_is_empty_for_each_payer_when_nothing_is_on_file
    client = replay_flow("on_file_none")

    assert_equal({ medicaid: [], medicare: [], private: [] }, Cov.on_file(DFN))
    assert_sent_the_flow(client, "on_file_none")
  end

  def test_on_file_sends_nothing_for_a_bad_dfn
    client = replay
    assert_nil Cov.on_file("0")
    assert_empty client.calls
  end

  def test_add_medicaid_files_the_number_and_state_on_the_record_and_the_end_date_on_the_row
    client = replay_flow("add_medicaid")
    got = Cov.add_medicaid(DFN, effective_on: "01/01/2026", ends_on: "12/31/2027", number: "ZZ4900001",
                                state_ien: WASHINGTON, coverage: nil)

    assert_equal({ success: true, error: nil, message: "", record_ien: "3", multiple_ien: "3260101" }, got)
    assert_sent_the_flow(client, "add_medicaid")
    record, row = wire(client)
    assert_equal "AGGMDNUM=ZZ4900001#{FS}AGGMDSTE=#{WASHINGTON}", record[1].last
    assert_equal [ "Medicaid Eligibility", "3", "", "AGGMDESD=01/01/2026#{FS}AGGMDEED=12/31/2027" ], row[1][2..]
    assert_equal %w[AGGRPC AGGRPC], [ record.last, row.last ]
  end

  def test_add_medicare_sends_the_part_by_its_window_choice_name
    client = replay_flow("add_medicare")
    got = Cov.add_medicare(DFN, name: "ZEPHYR,QUINN", number: "1EG4TE5MK73", effective_on: "01/01/2026",
                                ends_on: "12/31/2027", part: "b")

    assert got[:success], got.inspect
    assert_sent_the_flow(client, "add_medicare")
    assert_equal "AGGMCESD=01/01/2026#{FS}AGGMCEED=12/31/2027#{FS}AGGMCCOV=PART B", wire(client).last[1].last
  end

  def test_add_medicare_refuses_a_part_it_cannot_name_before_sending
    client = replay
    assert_raises(ArgumentError) do
      Cov.add_medicare(DFN, roi_on: "01/01/2026", name: "X", number: "1", effective_on: "01/01/2026", part: "C")
    end
    assert_empty client.calls
  end

  def test_add_private_insurance_files_through_ags_insurance_window
    client = replay_flow("add_private")
    got = Cov.add_private_insurance(DFN, insurer_ien: 5, policy_holder: "ZEPHYR,QUINN", member_number: "ZZM49",
                                         effective_on: "01/01/2026", ends_on: "12/31/2027")

    assert_equal({ success: true, error: nil, record_ien: "1", policy_holder_ien: "1" }, got)
    assert_sent_the_flow(client, "add_private")
    rpc, (proc, dfn, record, holder, parms), context = wire(client).last
    assert_equal [ "AGG UPDATE PRIVATE INSUR", "A", DFN.to_s, "", "", "AGGRPC" ], [ rpc, proc, dfn, record, holder, context ]
    assert_equal %w[AGGPIINS=5 AGGPIHLN=ZEPHYR,QUINN AGGPIMBN=ZZM49 AGGPIESD=01/01/2026 AGGPIEED=12/31/2027
                    AGGPHESD=01/01/2026 AGGPHEED=12/31/2027], parms.split(FS)
  end

  def test_add_private_insurance_refuses_before_sending_without_holder_member_or_start
    client = replay
    assert_raises(ArgumentError) do
      Cov.add_private_insurance(DFN, insurer_ien: 5, policy_holder: "", member_number: "M", effective_on: "01/01/2026")
    end
    assert_raises(ArgumentError) do
      Cov.add_private_insurance(DFN, insurer_ien: 5, policy_holder: "H", member_number: "M", effective_on: "13/01/2026")
    end
    assert_empty client.calls
  end
end
