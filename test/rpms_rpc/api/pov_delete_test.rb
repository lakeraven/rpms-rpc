# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/pov"
require_relative "../captured_replies"

# Pov.delete (BGOVPOV DEL, DEL^BGOVPOV). The replies are the build's
# (test/fixtures/captured_replies/pov-delete.yml): each flow run as
# PROFILE,MD on a throwaway container, on a diagnosis setup filed for DFN
# 990024 from its problem, recorded and replayed through CiaClient. The
# delete is proven live (test/live/pov_add_live_test.rb).
class PovDeleteTest < Minitest::Test
  SLUG = "pov-delete"
  DFN = 990_024
  POV = 206
  PROBLEM = 149

  def teardown
    RpmsRpc.reset!
  end

  def replay_flow(name)
    client = CapturedReplies::ReplayCiaClient.new(CapturedReplies.flow_script(SLUG, name))
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def sent(client) = client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params] ] }

  def test_delete_removes_the_diagnosis_and_reads_it_gone
    client = replay_flow("delete")

    result = RpmsRpc::Pov.delete(DFN, POV, problem_ien: PROBLEM)

    assert result[:success], result.inspect
    assert_equal POV, result[:ien]
    assert_equal CapturedReplies.flow_calls(SLUG, "delete"), sent(client)
    assert_equal [ "BGOVPOV DEL", [ "206", "149" ] ], sent(client)[1], "VPOV, then the problem (BGOVPOV.m:196)"
  end

  def test_another_patients_diagnosis_is_not_sent
    client = replay_flow("delete_wrong_patient")

    result = RpmsRpc::Pov.delete(990_025, POV, problem_ien: PROBLEM)

    assert_equal :wrong_patient, result[:error]
    refute_includes client.rpcs_called, "BGOVPOV DEL"
  end

  def test_a_diagnosis_not_on_file_is_not_sent
    client = replay_flow("delete_again")

    result = RpmsRpc::Pov.delete(DFN, POV, problem_ien: PROBLEM)

    assert_equal :not_found, result[:error]
    refute_includes client.rpcs_called, "BGOVPOV DEL"
  end

  def test_ids_the_delete_cannot_take_are_refused_before_the_wire
    client = replay_flow("delete")

    refute RpmsRpc::Pov.delete(0, POV)[:success]
    refute RpmsRpc::Pov.delete(DFN, "")[:success]
    assert_includes RpmsRpc::Pov.delete(DFN, POV, problem_ien: "x")[:error], "problem_ien"
    assert_empty sent(client)
  end
end
