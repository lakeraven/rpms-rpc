# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/mock_client"

# Vital.add_stock over stock VistA GMV ADD VM (#458), read back through
# GMV EXTRACT REC. Replies follow the M routines: EN1^GMVDCSAV
# (GMVDCSAV.m:14-97), GETVM^GMVGETD (GMVGETD.m:17-31, rows GMVGETD2.m:9-36)
# and TYPE^GMVUTL8 (GMVUTL8.m:30-37). Mock tier only; the live spec is a
# separate step.
class VitalStockTest < Minitest::Test
  Vital = RpmsRpc::Vital
  TAKEN = Time.new(2026, 11, 19, 9, 30, 15)
  NONE = [ "0^NO BLOOD PRESSURE ENTERED WITHIN THIS PERIOD" ].freeze

  # A MockClient answering each RPC from a queue, in call order.
  class Scripted < RpmsRpc::MockClient
    attr_reader :sent

    def initialize(script)
      super()
      set_authenticated(true)
      @script = script.transform_values(&:dup)
      @sent = []
    end

    def call_rpc(rpc, *params) = Array(answer(rpc, params)).join("\r\n")
    def call_rpc_lines(rpc, *params) = RpmsRpc::Reply.from_wire(Array(answer(rpc, params)).map(&:b))

    private

    def answer(rpc, params)
      @sent << [ rpc, params ]
      queue = @script[rpc] or raise "unscripted #{rpc}"
      raise "no reply left for #{rpc}" if queue.empty?

      queue.shift
    end
  end

  def teardown = RpmsRpc.reset!

  def script(hash)
    @client = Scripted.new(hash)
    RpmsRpc.configure { |cfg| cfg.client = @client }
  end

  def bp_save(after:, add: [ [] ])
    script("GMV GET VITAL TYPE IEN" => [ "1" ], "GMV ADD VM" => add,
           "GMV EXTRACT REC" => [ NONE, after ])
    Vital.add_stock(42, [ { abbreviation: "BP", value: "120/80" } ],
                    location_ien: 67, entered_by_duz: 87, taken_at: TAKEN)
  end

  def test_sends_the_gmvdata_record_and_reads_the_row_back
    result = bp_save(after: [ "5150^11/19/26@09:30   BLOOD PRESSURE: 120/80  _PROVIDER,ONE" ])

    assert_equal({ success: true, saved: [ { abbreviation: "BP", value: "120/80", vital_ien: 5150 } ], errors: [] }, result)
    rpcs = @client.sent.map(&:first)
    assert_equal [ "GMV GET VITAL TYPE IEN", "GMV EXTRACT REC", "GMV ADD VM", "GMV EXTRACT REC" ], rpcs
    assert_equal [ "BLOOD PRESSURE" ], @client.sent[0][1]
    assert_equal [ "3261119.093015^42^1;120/80;^67^87*" ], @client.sent[2][1]
    assert_equal [ "42^3261119.093115^BP^3261119.093015" ], @client.sent[1][1]
  end

  def test_qualifiers_follow_the_asterisk_colon_separated
    script("GMV GET VITAL TYPE IEN" => [ "9" ], "GMV ADD VM" => [ [] ],
           "GMV EXTRACT REC" => [ [ "0^NO WEIGHT ENTERED" ], [ "77^11/19/26@09:30   WEIGHT: 180 lb" ] ])
    result = Vital.add_stock(42, { abbreviation: "WT", value: 180, units: "lb", qualifier_iens: [ 2, 38 ] },
                             location_ien: 67, entered_by_duz: 87, taken_at: TAKEN)

    assert result[:success]
    assert_equal [ "3261119.093015^42^9;180;^67^87*2:38" ], @client.sent[2][1]
  end

  def test_an_error_reply_is_failure
    result = bp_save(add: [ [ "ERROR: The value is not valid." ] ], after: NONE)

    refute result[:success]
    assert_equal "The value is not valid.", result[:errors].first[:error_message]
  end

  def test_no_new_row_after_an_empty_reply_is_failure
    result = bp_save(after: NONE)

    refute result[:success]
    assert_empty result[:saved]
  end

  def test_an_empty_read_back_is_failure
    result = bp_save(after: [])

    refute result[:success]
    assert_match(/no reply after/, result[:errors].first[:error_message])
  end

  def test_an_unknown_type_name_on_the_server_sends_no_save
    script("GMV GET VITAL TYPE IEN" => [ "0" ])
    result = Vital.add_stock(42, { abbreviation: "P", value: 80 }, location_ien: 67, entered_by_duz: 87, taken_at: TAKEN)

    refute result[:success]
    assert_equal [ "GMV GET VITAL TYPE IEN" ], @client.sent.map(&:first)
  end

  def test_out_of_range_values_are_refused_before_any_call
    script({})
    [ { abbreviation: "BP", value: "80/120" }, { abbreviation: "BP", value: "400/80" },
      { abbreviation: "T", value: 130 }, { abbreviation: "T", value: "98.6", units: "C" },
      { abbreviation: "P", value: "80.5" }, { abbreviation: "PN", value: 11 },
      { abbreviation: "WT", value: 0 }, { abbreviation: "PO2", value: 101 },
      { abbreviation: "TMP", value: 98 }, { abbreviation: "WT", value: 180, qualifier_iens: [ "x" ] } ].each do |m|
      assert_raises(ArgumentError, m.inspect) do
        Vital.add_stock(42, [ m ], location_ien: 67, entered_by_duz: 87, taken_at: TAKEN)
      end
    end
    assert_empty @client.sent
  end

  def test_bad_ids_are_refused_before_any_call
    script({})
    assert_raises(ArgumentError) { Vital.add_stock(0, [ { abbreviation: "P", value: 80 } ], location_ien: 67, entered_by_duz: 87) }
    assert_raises(ArgumentError) { Vital.add_stock(42, [ { abbreviation: "P", value: 80 } ], location_ien: nil, entered_by_duz: 87) }
    assert_raises(ArgumentError) { Vital.add_stock(42, [], location_ien: 67, entered_by_duz: 87) }
    assert_empty @client.sent
  end
end
