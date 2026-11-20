# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/vital"
require "rpms_rpc/fileman_date_parser"

# Vital.add_stock files a vital through stock VistA GMV ADD VM and proves it
# by reading the new GMV EXTRACT REC row back (#458).
#
# WRITES against a disposable local container only.
class VitalAddStockLiveTest < LiveSpec::Test
  runs_as "PROV123"
  writes!

  DFN = 2
  LOCATION_IEN = 6

  def test_a_blood_pressure_is_filed_and_read_back
    taken = server_now - (rand(30..3000) * 86_400)
    saved = RpmsRpc::Vital.add_stock(DFN, [ { abbreviation: "BP", value: "124/78" }, { abbreviation: "P", value: 72 } ],
                                     location_ien: LOCATION_IEN, entered_by_duz: client.duz, taken_at: taken)

    assert saved[:success], saved.inspect
    assert_equal %w[BP P], saved[:saved].map { |s| s[:abbreviation] }
    assert(saved[:saved].all? { |s| s[:vital_ien].positive? })
    puts "\n#{persona}: GMV rows #{saved[:saved].map { |s| s[:vital_ien] }.inspect} at #{taken}"
  end

  private

  def server_now
    RpmsRpc::FilemanDateParser.parse_datetime(Array(client.call_rpc("ORWU DT", "NOW")).first.to_s) ||
      flunk("ORWU DT NOW did not yield a FileMan datetime")
  end
end
