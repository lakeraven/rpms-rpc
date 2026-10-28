# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/immunization_lot"
require "rpms_rpc/api/ddr_fileman"

# ImmunizationLot reads IMMUNIZATION LOT (#9999999.41) with DDR GETS ENTRY
# DATA and DDR LISTER, because neither registered lot RPC returns the lot's
# VACCINE SOURCE (.13). The demo site holds no lots, so the spec files one
# with DDR FILER, the stock FileMan filer, reads it back both ways, and files
# it INACTIVE afterwards.
#
# It WRITES, so it runs only against a disposable local container.
class ImmunizationLotLiveTest < LiveSpec::Test
  writes!

  TETANUS_TOXOID = "104"   # IMMUNIZATION (#9999999.14), HL7-CVX CODE 35
  MANUFACTURER = "100"     # IMMUNIZATION MANUFACTURER (#9999999.04)

  def test_a_filed_vfc_lot_reads_back_with_its_source_and_vaccine
    ien = file_lot!
    begin
      lot = RpmsRpc::ImmunizationLot.find(ien)

      assert_equal({ ien: ien.to_i, lot_number: @number, active: true, vaccine_ien: 104, vaccine: "TETANUS TOXOID",
                     cvx: "35", expiration_date: Date.new(2027, 12, 31), source: "v", source_label: "VFC" }, lot)
      assert_includes RpmsRpc::ImmunizationLot.list, lot, "DDR LISTER did not list lot #{ien} as find reads it"
      puts "\n#{persona}: lot #{ien} (#{@number}) reads back VFC, CVX 35"
    ensure
      retire(ien)
    end
  end

  def test_an_unknown_lot_is_nil
    assert_nil RpmsRpc::ImmunizationLot.find(999_999_999)
  end

  private

  def file_lot!
    @number = "LIVESPEC-#{Time.now.strftime('%H%M%S')}"
    rows = { ".01" => @number, ".02" => MANUFACTURER, ".03" => "0", ".04" => TETANUS_TOXOID,
             ".09" => "3271231", ".13" => "v" }.map do |field, value|
      { file: RpmsRpc::ImmunizationLot::FILE, field: field, iens: "+1,", value: value }
    end
    filed = RpmsRpc::DdrFileman.filer(mode: "ADD", rows: rows)
    assert filed && filed[:success], "DDR FILER could not file a lot: #{filed.inspect}"
    filed[:iens].fetch(1)
  end

  def retire(ien)
    RpmsRpc::DdrFileman.filer(mode: "EDIT",
      rows: [ { file: RpmsRpc::ImmunizationLot::FILE, field: ".03", iens: "#{ien},", value: "1" } ])
    refute RpmsRpc::ImmunizationLot.find(ien)&.dig(:active), "lot #{ien} could not be filed INACTIVE again"
  end
end
