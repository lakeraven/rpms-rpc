# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/vaccine_lot"

class VaccineLotTest < Minitest::Test
  def setup
    RpmsRpc.mock! do |m|
      m.seed_collection(:vaccine_lot_list, [
        lot_attrs(ien: "101", lot_number: "LOT-A", facility_ien: "55"),
        lot_attrs(ien: "102", lot_number: "LOT-B", facility_ien: "66", expiration_date: "BAD")
      ])
      m.seed(:vaccine_lot_detail, "101", lot_attrs(ien: "101", lot_number: "LOT-A", facility_ien: "55"))
    end
  end

  def teardown
    RpmsRpc.reset!
  end

  def test_for_facility_returns_lots_without_facility_filter
    lots = RpmsRpc::VaccineLot.for_facility

    assert_equal 2, lots.length
    assert_equal "LOT-A", lots.first[:lot_number]
    assert_equal Date.new(2026, 12, 31), lots.first[:expiration_date]

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BIPC LOTLIST" }
    assert_equal [], call[:params]
  end

  def test_for_facility_passes_facility_filter
    RpmsRpc::VaccineLot.for_facility(55)

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BIPC LOTLIST" }
    assert_equal [ "55" ], call[:params]
  end

  def test_find_returns_lot_detail
    lot = RpmsRpc::VaccineLot.find(101)

    assert_equal "101", lot[:ien]
    assert_equal "207", lot[:vaccine_code]
    assert_equal "PFIZER", lot[:manufacturer]
    assert_equal 120, lot[:doses_start]
    assert_equal 45, lot[:doses_unused]
  end

  def test_find_returns_nil_for_missing_lot
    assert_nil RpmsRpc::VaccineLot.find(999_999)
  end

  def test_invalid_values_are_handled_like_gateway
    lots = RpmsRpc::VaccineLot.for_facility

    assert_nil lots.last[:expiration_date]
    assert_nil RpmsRpc::VaccineLot.find(nil)
  end

  private

  def lot_attrs(overrides = {})
    {
      ien: "101",
      lot_number: "LOT-A",
      vaccine_code: "207",
      vaccine_display: "COVID-19 mRNA",
      manufacturer: "PFIZER",
      ndc_code: "59267-1000-01",
      funding_source: "VFC",
      status: "ACTIVE",
      expiration_date: "2026-12-31",
      doses_start: 120,
      doses_unused: 45,
      facility_ien: "55"
    }.merge(overrides)
  end
end
