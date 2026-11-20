# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/adt"
require_relative "../captured_replies"

# Adt.movements reads a patient's PATIENT MOVEMENT (#405) rows (rpms-rpc#747).
# Each test replays a flow the gem ran as PROVIDER,TEST on a throwaway
# container where DFN 4 was admitted, switched bed and discharged through
# stock $$ADD^BDGAPI (test/fixtures/captured_replies/adt-movements.yml).
class AdtMovementsTest < Minitest::Test
  SLUG = "adt-movements"

  def teardown
    RpmsRpc.reset!
  end

  def replay(flow)
    @client = CapturedReplies::ReplayCiaClient.new(CapturedReplies.flow_script(SLUG, flow))
    RpmsRpc.configure { |cfg| cfg.client = @client }
  end

  def sent = @client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params] ] }

  def test_a_stay_reads_back_as_ordered_movements_tied_to_the_admission
    replay("one_stay")

    admitted = Time.new(2026, 11, 17, 23, 0, 0)
    assert_equal [
      { ien: 1, at: admitted, transaction: :admission, transaction_name: "ADMISSION", type: "DIRECT",
        ward: "DEMO WARD", room_bed: "101-B", specialty: nil, admission_ien: 1, discharge_ien: 3 },
      { ien: 2, at: admitted, transaction: :specialty_transfer, transaction_name: "SPECIALTY TRANSFER",
        type: "PROVIDER/SPECIALTY CHANGE", ward: nil, room_bed: nil, specialty: "GENERAL MEDICINE",
        admission_ien: 1, discharge_ien: nil },
      { ien: 3, at: Time.new(2026, 11, 18, 23, 0, 0), transaction: :discharge, transaction_name: "DISCHARGE",
        type: "REGULAR DISCHARGE", ward: nil, room_bed: nil, specialty: nil, admission_ien: 1, discharge_ien: nil }
    ], RpmsRpc::Adt.movements(dfn: 4)
    assert_equal CapturedReplies.flow_calls(SLUG, "one_stay"), sent
  end

  def test_a_patient_never_admitted_has_no_movements
    replay("no_stay")

    assert_equal [], RpmsRpc::Adt.movements(dfn: 990_012)
  end

  def test_a_dfn_that_is_not_a_positive_integer_sends_nothing
    replay("no_stay")

    [ nil, 0, -4, "4 OR 1", "" ].each do |bad|
      assert_raises(ArgumentError) { RpmsRpc::Adt.movements(dfn: bad) }
    end
    assert_empty sent
  end
end
