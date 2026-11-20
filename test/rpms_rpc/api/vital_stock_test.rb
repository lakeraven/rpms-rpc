# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/vital"
require "rpms_rpc/api/vital_stock"
require_relative "../captured_replies"

# Vital.add_stock over stock VistA GMV ADD VM (#458), read back through
# GMV EXTRACT REC. The replies are the build's
# (test/fixtures/captured_replies/vital-stock.yml): add_stock run as
# PROVIDER,TEST on a throwaway container for synthetic DFN 990054 at DEMO
# PRIMARY CARE, recorded as flows and replayed through CiaClient. Each test
# that reaches the wire checks the gem sent exactly the recorded calls. The
# save against the server's clock is proven live by
# test/live/vital_add_stock_live_test.rb.
class VitalStockTest < Minitest::Test
  SLUG = "vital-stock"
  Vital = RpmsRpc::Vital
  DFN = 990_054
  LOCATION = 10
  DUZ = 200
  TAKEN = Time.new(2026, 11, 19, 9, 30, 15)

  def setup
    replay
  end

  def teardown = RpmsRpc.reset!

  # A client with no replies unless a flow is named: a test that reaches
  # the wire without one fails.
  def replay(flow = nil)
    @client = CapturedReplies::ReplayCiaClient.new(flow ? CapturedReplies.flow_script(SLUG, flow) : {})
    RpmsRpc.configure { |cfg| cfg.client = @client }
  end

  def sent = @client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params] ] }

  def save(flow, measurements, taken_at: TAKEN)
    replay(flow)
    Vital.add_stock(DFN, measurements, location_ien: LOCATION, entered_by_duz: DUZ, taken_at: taken_at)
  end

  def test_sends_the_gmvdata_record_and_reads_the_row_back
    result = save("bp", [ { abbreviation: "BP", value: "120/80" } ])

    assert_equal({ success: true, saved: [ { abbreviation: "BP", value: "120/80", vital_ien: 1 } ], errors: [] }, result)
    assert_equal CapturedReplies.flow_calls(SLUG, "bp"), sent
    assert_equal [ [ "GMV GET VITAL TYPE IEN", [ "BLOOD PRESSURE" ] ],
                   [ "GMV EXTRACT REC", [ "990054^3261119.093115^BP^3261119.093015" ] ],
                   [ "GMV ADD VM", [ "3261119.093015^990054^1;120/80;^10^200*" ] ],
                   [ "GMV EXTRACT REC", [ "990054^3261119.093115^BP^3261119.093015" ] ] ], sent
  end

  # The same reading is already filed at this second: the read-back before
  # the save lists it, so only the new row counts.
  def test_a_row_already_filed_in_the_window_is_not_taken_for_the_new_one
    result = save("bp_same_second", [ { abbreviation: "BP", value: "120/80" } ])

    assert result[:success], result.inspect
    assert_equal [ { abbreviation: "BP", value: "120/80", vital_ien: 2 } ], result[:saved]
    assert_equal CapturedReplies.flow_calls(SLUG, "bp_same_second"), sent
  end

  def test_qualifiers_follow_the_asterisk_colon_separated
    result = save("weight_qualified", { abbreviation: "WT", value: 180, units: "lb", qualifier_iens: [ 42, 72 ] })

    assert result[:success], result.inspect
    assert_equal [ { abbreviation: "WT", value: "180", vital_ien: 3 } ], result[:saved]
    assert_equal [ "3261119.093015^990054^9;180;^10^200*42:72" ], sent[2].last
    assert_equal CapturedReplies.flow_calls(SLUG, "weight_qualified"), sent
  end

  def test_each_measurement_is_saved_and_read_back_in_turn
    result = save("bp_and_pulse", [ { abbreviation: "BP", value: "124/78" }, { abbreviation: "P", value: 72 } ],
                  taken_at: Time.new(2026, 11, 19, 10, 15, 0))

    assert result[:success], result.inspect
    assert_equal [ { abbreviation: "BP", value: "124/78", vital_ien: 4 }, { abbreviation: "P", value: "72", vital_ien: 5 } ],
                 result[:saved]
    assert_equal CapturedReplies.flow_calls(SLUG, "bp_and_pulse"), sent
  end

  def test_out_of_range_values_are_refused_before_any_call
    [ { abbreviation: "BP", value: "80/120" }, { abbreviation: "BP", value: "400/80" },
      { abbreviation: "T", value: 130 }, { abbreviation: "T", value: "98.6", units: "C" },
      { abbreviation: "P", value: "80.5" }, { abbreviation: "PN", value: 11 },
      { abbreviation: "WT", value: 0 }, { abbreviation: "PO2", value: 101 },
      { abbreviation: "TMP", value: 98 }, { abbreviation: "WT", value: 180, qualifier_iens: [ "x" ] } ].each do |m|
      assert_raises(ArgumentError, m.inspect) do
        Vital.add_stock(DFN, [ m ], location_ien: LOCATION, entered_by_duz: DUZ, taken_at: TAKEN)
      end
    end
    assert_empty @client.calls
  end

  def test_bad_ids_are_refused_before_any_call
    assert_raises(ArgumentError) { Vital.add_stock(0, [ { abbreviation: "P", value: 80 } ], location_ien: LOCATION, entered_by_duz: DUZ) }
    assert_raises(ArgumentError) { Vital.add_stock(DFN, [ { abbreviation: "P", value: 80 } ], location_ien: nil, entered_by_duz: DUZ) }
    assert_raises(ArgumentError) { Vital.add_stock(DFN, [], location_ien: LOCATION, entered_by_duz: DUZ) }
    assert_empty @client.calls
  end
end
