# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/mock_client"

# Replies are the DDR lines a fresh rpms-ydb e9b78c8 sent for a lot the live
# spec filed (test/live/immunization_lot_live_test.rb), after it was retired.
class ImmunizationLotTest < Minitest::Test
  LOT_GETS = <<~DATA.chomp
    [Data]
    9999999.41^1^.01^LIVESPEC-000315^LIVESPEC-000315
    9999999.41^1^.03^1^INACTIVE
    9999999.41^1^.04^104^TETANUS TOXOID
    9999999.41^1^.09^3271231^DEC 31, 2027
    9999999.41^1^.13^v^VFC
  DATA
  VACCINE_GETS = <<~DATA.chomp
    [Data]
    9999999.14^104^.01^TETANUS TOXOID^
    9999999.14^104^.03^35^
  DATA
  LISTER = "[Data]\n1^LIVESPEC-000315^1^104^3271231^v"

  LOT = { ien: 1, lot_number: "LIVESPEC-000315", active: false, vaccine_ien: 104, vaccine: "TETANUS TOXOID",
          cvx: "35", expiration_date: Date.new(2027, 12, 31), source: "v", source_label: "VFC" }.freeze

  def setup
    RpmsRpc.mock! do |m|
      m.seed_text(:ddr_gets_entry_data, gets("9999999.41", "1,", ".01;.03;.04;.09;.13", "IE"), LOT_GETS)
      m.seed_text(:ddr_gets_entry_data, gets("9999999.14", "104,", ".01;.03", "I"), VACCINE_GETS)
      m.seed_text(:ddr_lister, RpmsRpc::DdrFileman.lister_param(
        file: "9999999.41", fields: ".01I;.03I;.04I;.09I;.13I", flags: "IP").to_s, LISTER)
    end
  end

  def teardown
    RpmsRpc.reset!
  end

  def test_find_reads_the_lot_its_source_and_its_vaccine_cvx
    assert_equal LOT, RpmsRpc::ImmunizationLot.find(1)
  end

  def test_list_lists_each_lot_in_the_shape_find_returns
    assert_equal [ LOT ], RpmsRpc::ImmunizationLot.list
  end

  def test_find_refuses_an_id_that_is_not_an_ien_without_a_call
    [ nil, "", "0", "-1", "1a" ].each { |id| assert_nil RpmsRpc::ImmunizationLot.find(id) }
    assert_empty RpmsRpc.client.received_calls
  end

  private

  def gets(file, iens, fields, flags)
    RpmsRpc::DdrFileman.gets_entry_param(file: file, iens: iens, fields: fields, flags: flags).to_s
  end
end
