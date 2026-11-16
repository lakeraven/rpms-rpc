# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/problem"
require "rpms_rpc/api/authentication"

# What the integrated problem list reads and the component security check
# send, and refuse before anything reaches the wire. The replies here are
# rows the pinned build sent (bcer-9.0-20261116-2a9b3fe-ydb, demo patient
# DFN 2 and SYS123); filing and reading back are proven live
# (test/live/problem_integrated_live_test.rb).
class ProblemIntegratedTest < Minitest::Test
  P_ROW = "P^1^^^DIC-1^CHRONIC^04/10/2023^*TYPE 2 DIABETES MELLITUS^E11.9^^U^^^^^0^0^^0^^^3261116.032715^^^11/16/2026^^"

  class RecordingClient
    attr_reader :calls

    def initialize(replies = {}) = (@replies = replies) && (@calls = [])

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

  def test_integrated_sends_every_formal_and_reads_the_p_row
    use("BGOPROB GET" => [ P_ROW ])
    problem = RpmsRpc::Problem.integrated(2).first

    assert_equal [ "BGOPROB GET", [ "2", "", "", "", "" ] ], @client.calls.last
    assert_equal [ 1, "DIC-1", "CHRONIC", "*TYPE 2 DIABETES MELLITUS", "E11.9", "U" ],
                 problem.values_at(:ien, :number, :status, :narrative, :icd_code, :problem_class)
    assert_equal Date.new(2023, 4, 10), problem[:onset]
    assert_equal Date.new(2026, 11, 16), problem[:recorded_on]
    assert_equal "3261116.032715", problem[:last_modified]
    assert_nil problem[:snomed_concept]
    refute problem[:used_as_pov]
  end

  def test_statuses_go_as_letters_and_anything_else_is_refused_unsent
    use("BGOPROB GET" => [])
    RpmsRpc::Problem.integrated(2, statuses: %w[a i])
    assert_equal "AI", @client.calls.last[1][1]
    [ "X", "A^I", "" ].each do |bad|
      assert_raises(ArgumentError, bad.inspect) { RpmsRpc::Problem.integrated(2, statuses: bad) }
    end
    assert_equal 1, @client.calls.size
  end

  def test_a_refused_read_raises_rather_than_reading_as_no_problems
    use("BGOPROB1 EDPROB" => [ "-1^Patient not found" ])
    assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Problem.coded_active(2) }
  end

  def test_invalid_ids_send_nothing
    use
    assert_empty RpmsRpc::Problem.integrated("0")
    assert_nil RpmsRpc::Problem.integrated_entry(nil)
    assert_empty RpmsRpc::Problem.coded_active("x")
    assert_empty @client.calls
  end

  def test_component_security_reads_the_reply_the_build_sent
    use("BGOUTL CHKSEC" => [ "1|1|0^0~|0~" ])
    answer = RpmsRpc::Authentication.component_security(
      keys: %w[XUPROGMODE PROVIDER NOSUCHKEY], parameters: [ "BGO DISABLE PROB LIST EDITING", "BGO DISABLE POV EDITING" ]
    )

    assert_equal [ "BGOUTL CHKSEC", [ "XUPROGMODE|PROVIDER|NOSUCHKEY^BGO DISABLE PROB LIST EDITING|BGO DISABLE POV EDITING" ] ],
                 @client.calls.last
    assert_equal({ "XUPROGMODE" => true, "PROVIDER" => true, "NOSUCHKEY" => false }, answer[:keys])
    assert_equal({ user_setting: 0, granted_by_class: nil }, answer[:parameters]["BGO DISABLE POV EDITING"])
  end

  def test_component_security_raises_on_a_reply_that_does_not_answer_each_name
    use("BGOUTL CHKSEC" => [ "-1053^Your user id (DUZ) does not match that of the user currently logged in." ])
    assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Authentication.component_security(keys: %w[XUPROGMODE]) }
    use("BGOUTL CHKSEC" => [ "1^" ])
    assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Authentication.component_security(keys: %w[XUPROGMODE PROVIDER]) }
  end

  def test_component_security_refuses_names_the_piece_cannot_carry_unsent
    use
    [ { keys: [ "A|B" ] }, { parameters: [ "X^Y" ] }, { keys: [ " " ] } ].each do |args|
      assert_raises(ArgumentError, args.inspect) { RpmsRpc::Authentication.component_security(**args) }
    end
    assert_equal({ keys: {}, parameters: {} }, RpmsRpc::Authentication.component_security)
    assert_empty @client.calls
  end
end
