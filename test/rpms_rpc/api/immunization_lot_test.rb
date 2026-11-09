# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/immunization_lot"
require_relative "../captured_replies"

# ImmunizationLot reads the replies a fresh rpms-ydb container sent for the lot
# test/live/immunization_lot_live_test.rb filed and then retired
# (test/fixtures/captured_replies/immunization-lot.yml), replayed through
# CiaClient. The live spec proves the round trip; this pins the mapping of
# those exact bytes, and that a bad id reaches no wire.
class ImmunizationLotTest < Minitest::Test
  SLUG = "immunization-lot"
  GETS = "DDR GETS ENTRY DATA"
  LISTER = "DDR LISTER"

  LOT = { ien: 1, lot_number: "LIVESPEC-190441", active: false, vaccine_ien: 104, vaccine: "TETANUS TOXOID",
          cvx: "35", expiration_date: Date.new(2027, 12, 31), source: "v", source_label: "VFC" }.freeze

  def teardown
    RpmsRpc.reset!
  end

  def replay(script)
    client = CapturedReplies::ReplayCiaClient.new(script)
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def capture(name) = CapturedReplies.raw(SLUG, name)
  def sent(name) = CapturedReplies.file(SLUG).fetch("captures").find { |c| c["name"] == name }.fetch("inputs")

  def test_find_reads_the_lot_its_source_and_its_vaccine_cvx
    client = replay(GETS => [ capture("lot"), capture("vaccine") ])

    assert_equal LOT, RpmsRpc::ImmunizationLot.find(1)
    assert_equal [ sent("lot"), sent("vaccine") ], client.calls.map { |c| c[:params] },
                 "find sends the reads the capture made"
  end

  def test_list_lists_each_lot_in_the_shape_find_returns
    client = replay(LISTER => [ capture("lister") ], GETS => [ capture("vaccine") ])

    assert_equal [ LOT ], RpmsRpc::ImmunizationLot.list
    assert_equal sent("lister"), client.calls.first[:params]
  end

  def test_a_lot_that_does_not_exist_is_nil
    replay(GETS => [ capture("no_such_lot") ])

    assert_nil RpmsRpc::ImmunizationLot.find(999_999_999)
  end

  def test_find_refuses_an_id_that_is_not_an_ien_without_a_call
    client = replay({})

    [ nil, "", "0", "-1", "1a" ].each { |id| assert_nil RpmsRpc::ImmunizationLot.find(id) }
    assert_empty client.calls
  end
end
