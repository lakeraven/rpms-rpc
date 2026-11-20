# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/emergency_room"
require_relative "../captured_replies"

# EmergencyRoom.visit reads one ER VISIT (#9009080) back from the build
# (rpms-rpc#747). Each test replays a flow the gem ran as PROVIDER,TEST on a
# throwaway container (test/fixtures/captured_replies/er-visit.yml).
class EmergencyRoomTest < Minitest::Test
  Er = RpmsRpc::EmergencyRoom
  SLUG = "er-visit"

  def teardown
    RpmsRpc.reset!
  end

  def replay(flow, script = CapturedReplies.flow_script(SLUG, flow))
    @client = CapturedReplies::ReplayCiaClient.new(script)
    RpmsRpc.configure { |cfg| cfg.client = @client }
  end

  def sent = @client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params] ] }
  def visit_ien = Integer(CapturedReplies.flow(SLUG, "on_file").first.dig("inputs", 0, "IENS").delete(","))

  def test_an_er_visit_comes_back_typed_with_arrival_mode_triage_and_disposition
    replay("on_file")

    visit = Er.visit(dfn: 4, visit_ien: visit_ien)

    assert_equal({ ien: visit_ien, dfn: 4, arrived_at: Time.new(2026, 11, 19, 21, 40, 0), pcc_visit_ien: nil,
                   visit_type: { ien: 3, name: "UNSCHEDULED" },
                   mode_of_transport: { ien: 176, name: "PRIVATE VEHICLE/WALK IN" },
                   presenting_complaint: "CHEST PAIN", esi: 2, ed_provider: nil,
                   triage_nurse: { ien: visit[:triage_nurse][:ien], name: "PROVIDER,TEST" },
                   triage_nurse_at: Time.new(2026, 11, 19, 21, 52, 0),
                   disposition: { ien: 164, name: "HOME" }, departed_at: Time.new(2026, 11, 19, 23, 15, 0),
                   transfer_to: nil }, visit)
    assert_equal CapturedReplies.flow_calls(SLUG, "on_file"), sent
  end

  def test_another_patients_er_visit_is_nil
    replay("other_patient")

    assert_nil Er.visit(dfn: 5, visit_ien: visit_ien)
  end

  def test_an_er_visit_the_build_does_not_have_is_nil
    replay("not_on_file")

    assert_nil Er.visit(dfn: 4, visit_ien: 999_999)
  end

  def test_an_id_that_is_not_a_positive_integer_sends_nothing
    replay("on_file")

    [ nil, 0, -4, "4 OR 1", "" ].each do |bad|
      assert_raises(ArgumentError) { Er.visit(dfn: bad, visit_ien: 1) }
      assert_raises(ArgumentError) { Er.visit(dfn: 4, visit_ien: bad) }
    end
    assert_empty sent
  end
end
