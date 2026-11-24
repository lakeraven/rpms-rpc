# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"

# What the sign list, visit providers and order display-group reads send,
# how they read the rows the pinned build sent (bcer-9.0-20261116-2a9b3fe-ydb:
# demo patient DFN 2's sign list, visit 2's providers), and what they refuse
# before the wire. Proven live in test/live/clinical_context_reads_live_test.rb.
class ClinicalContextReadsTest < Minitest::Test
  class RecordingClient
    attr_reader :calls

    def initialize(replies) = (@replies = replies) && (@calls = [])

    def call_rpc(name, *params)
      @calls << [ name, params ]
      @replies.fetch(name, [])
    end

    def create_context(*) = true
    def current_context = "CIAV VUECENTRIC"
  end

  def use(replies = {})
    @client = RecordingClient.new(replies)
    RpmsRpc.configure { |cfg| cfg.client = @client }
  end

  def teardown
    RpmsRpc.reset!
  end

  def test_the_sign_list_reads_action_and_reactant
    use("BEHOART SIGNLIST" => [ "1^Verify Adverse Reaction to PENICILLIN", "7^Adverse Reaction to LATEX" ])
    assert_equal [ { ien: 1, action: :verify, reactant: "PENICILLIN" }, { ien: 7, action: :sign, reactant: "LATEX" } ],
                 RpmsRpc::Allergy.awaiting_signature(2)
    assert_equal [ "BEHOART SIGNLIST", [ "2", "" ] ], @client.calls.last
    RpmsRpc::Allergy.awaiting_signature(2, skip_autoverify: true)
    assert_equal [ "2", "1" ], @client.calls.last[1]
  end

  def test_the_sign_list_nka_row_is_an_answer_and_other_error_rows_raise
    use("BEHOART SIGNLIST" => [ "-2^No Known Allergies" ])
    assert_equal [ { ien: nil, action: :sign, reactant: nil, nka: true } ], RpmsRpc::Allergy.awaiting_signature(2)
    use("BEHOART SIGNLIST" => [ "-1^Patient locked" ])
    assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Allergy.awaiting_signature(2) }
    use("BEHOART SIGNLIST" => [ "1^Something else" ])
    assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Allergy.awaiting_signature(2) }
  end

  def test_providers_name_the_visit_in_the_visit_string
    use("BEHOENCX GETPRV" => [ "4^MANAGER,SYSTEM^1^" ])
    assert_equal [ { duz: 4, name: "MANAGER,SYSTEM", primary: true, event_datetime: nil } ], RpmsRpc::Encounter.providers(4, 2)
    assert_equal [ "BEHOENCX GETPRV", [ "4", ";;;2", "" ] ], @client.calls.last
    RpmsRpc::Encounter.providers(4, 2, primary_only: true)
    assert_equal "1", @client.calls.last[1][2]
  end

  def test_display_group_ien_and_order_checking
    use("ORWORDG IEN" => [ "1" ], "ORWDXC ON" => [ "E" ])
    assert_equal 1, RpmsRpc::Order.display_group_ien("ALL SERVICES")
    assert_equal [ "ORWORDG IEN", [ "ALL SERVICES" ] ], @client.calls.last
    assert RpmsRpc::Order.checking_enabled?
    use("ORWORDG IEN" => [ "" ], "ORWDXC ON" => [ "X" ])
    assert_nil RpmsRpc::Order.display_group_ien("NOPE")
    assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Order.checking_enabled? }
  end

  def test_invalid_input_sends_nothing
    use
    assert_empty RpmsRpc::Allergy.awaiting_signature("0")
    assert_empty RpmsRpc::Encounter.providers(4, "2;3")
    assert_nil RpmsRpc::Order.display_group_ien("A^B")
    assert_nil RpmsRpc::Order.display_group_ien(" ")
    assert_empty @client.calls
  end
end

# PatientGoal.for_patient reads GETGOAL's global array, goal by goal, as the
# pinned build sent it for a goal filed through BEHOPGAP ADDGOAL (an empty
# type line kept) and one with two types.
class PatientGoalReadTest < Minitest::Test
  REPLY = [ "1^GOAL SET^3261116^MANAGER,SYSTEM^3261116.194704^DEMO IHS CLINIC^MANAGER,SYSTEM^3261116^3261216^A;ACTIVE^1",
            "", "Walk 30 minutes a day", "Blood sugar control",
            "2^GOAL SET^3261116^MANAGER,SYSTEM^3261116.200031^DEMO IHS CLINIC^MANAGER,SYSTEM^3261116^3261216^D;DELETED/ENTERED IN ERROR^2",
            "PHYSICAL ACTIVITY^NUTRITION", "Walk 30 minutes a day", "Blood sugar control",
            "REVIEW^3261120^Walked three days this week" ].freeze

  def use(reply)
    @client = ClinicalContextReadsTest::RecordingClient.new("BEHOPGAP GETGOAL" => reply)
    RpmsRpc.configure { |cfg| cfg.client = @client }
  end

  def teardown
    RpmsRpc.reset!
  end

  def test_goals_read_line_by_line
    use(REPLY)
    first, second = RpmsRpc::PatientGoal.for_patient(990_047)
    assert_equal [ "BEHOPGAP GETGOAL", [ "990047" ] ], @client.calls.last
    assert_equal [ 1, 1, "A", [], "Walk 30 minutes a day", [] ], first.values_at(:ien, :goal_number, :status, :types, :name, :reviews)
    assert_equal [ "D", "DELETED/ENTERED IN ERROR", %w[PHYSICAL\ ACTIVITY NUTRITION] ], second.values_at(:status, :status_name, :types)
    assert_equal [ { date: Date.new(2026, 11, 20), note: "Walked three days this week" } ], second[:reviews]
    assert_equal Date.new(2026, 12, 16), first[:follow_up_date]
  end

  def test_a_reply_off_the_layout_or_refused_raises
    use([ "Walk 30 minutes a day" ])
    assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::PatientGoal.for_patient(990_047) }
    use([ "-1^No patient" ])
    assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::PatientGoal.for_patient(990_047) }
  end
end
