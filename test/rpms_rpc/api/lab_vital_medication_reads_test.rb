# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"

# What the vitals, lab and medication-profile reads send, how they read the
# rows the pinned build sent (bcer-9.0-20261116-2a9b3fe-ydb: demo patient
# DFN 2's vitals list and grid, the empty lab and medication answers), and
# what they refuse before the wire. The build files no lab result, lab order
# or medication, so those rows are laid out from the routines (GRID^LR7OGMG,
# LIST^ORQOR1, GETRXS^BEHORXFN), not captured. Proven live in
# test/live/lab_vital_medication_reads_live_test.rb.
class LabVitalMedicationReadsTest < Minitest::Test
  class RecordingClient
    attr_reader :calls

    def initialize(replies) = (@replies = replies) && (@calls = [])

    def call_rpc(name, *params)
      @calls << [ name, params ]
      @replies.fetch(name, [])
    end

    def create_context(*) = true
    def current_context = "CIAV VUECENTRIC"
  end

  GRID = [ "22^1^2", "3^3^TEMPERATURE^TMP^F^^^^1^2", "5^5^PULSE^PU^/min^60^100^^1^2",
           *Array.new(20) { |i| "#{90 + i}^#{90 + i}^OTHER #{i}^O#{i}^^^^^0^2" },
           "1^3260825.09", "1^2^82^^4^", "1^1^99.1^H^9^ORAL" ].freeze

  def use(replies = {})
    @client = RecordingClient.new(replies)
    RpmsRpc.configure { |cfg| cfg.client = @client }
  end

  def teardown
    RpmsRpc.reset!
  end

  def test_latest_by_type_reads_the_list_row
    use("BEHOVM LIST" => [ "4^PULSE^PU^3260825.09^82 /min^^", "2^WEIGHT^WT^3260825.09^214 lb^97.069 kg^" ])
    rows = RpmsRpc::Vital.latest_by_type(2)
    assert_equal [ "BEHOVM LIST", [ "2", "", "", "", "", "", "", "" ] ], @client.calls.last
    assert_equal [ 4, "PULSE", "PU", "82 /min", nil ], rows.first.values_at(:measurement_ien, :name, :abbreviation, :value, :alternate_value)
    assert_equal "97.069 kg", rows.last[:alternate_value]
    assert_equal Time.new(2026, 8, 25, 9, 0), rows.first[:taken_at]
    use("BEHOVM LIST" => [ "PULSE^82" ])
    assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Vital.latest_by_type(2) }
  end

  def test_the_grid_resolves_results_to_their_vital_and_date
    use("BEHOVM GRID" => GRID)
    grid = RpmsRpc::Vital.grid(2, max_per_type: 5)
    assert_equal [ "2", "", "", "5", "", "", "-1", "", "", "" ], @client.calls.last[1]
    assert_equal 22, grid[:vitals].size
    assert_equal({ control_ien: 5, type_ien: 5, name: "PULSE", abbreviation: "PU", units: "/min", low: "60", high: "100",
                   percentile_rpc: nil, has_qualifiers: true }, grid[:vitals][1])
    assert_equal [ { abbreviation: "PU", taken_at: Time.new(2026, 8, 25, 9, 0), value: "82", flag: nil, measurement_ien: 4, qualifiers: nil },
                   { abbreviation: "TMP", taken_at: Time.new(2026, 8, 25, 9, 0), value: "99.1", flag: :high, measurement_ien: 9, qualifiers: "ORAL" } ],
                 grid[:results]
  end

  def test_a_grid_whose_counts_do_not_match_raises
    use("BEHOVM GRID" => GRID.first(5))
    assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Vital.grid(2) }
  end

  def test_lab_result_date_range_reads_newest_and_oldest
    use("ORWLRR NEWOLD" => [ "^" ])
    assert_equal({ newest: nil, oldest: nil }, RpmsRpc::Lab.result_date_range(2))
    use("ORWLRR NEWOLD" => [ "3261101.0815^3200105.1" ])
    assert_equal({ newest: Time.new(2026, 11, 1, 8, 15), oldest: Time.new(2020, 1, 5, 10, 0) }, RpmsRpc::Lab.result_date_range(2))
  end

  def test_specimen_reads_header_tests_and_text
    use("ORWLRR INTERIMG" => [ "2^CH^3261101.0815^72^SERUM^CH 1101 4^PROVIDER,TEST^^1^3261101.0815",
                               "175^GLUCOSE^    98^^mg/dL^70 - 110^^^^^^^^^2345-7", "177^SODIUM^   150^H^mmol/L^135 - 145",
                               " ", "Report Released Date/Time: NOV 01, 2026@09:00" ])
    got = RpmsRpc::Lab.specimen(2, from: "3261117")
    assert_equal [ "ORWLRR INTERIMG", [ "2", "3261117", "1", "1" ] ], @client.calls.last
    assert_equal [ "CH", 72, "SERUM", "CH 1101 4", "PROVIDER,TEST" ], got.values_at(:area, :specimen_ien, :specimen, :accession, :provider)
    assert_equal({ test_ien: 175, name: "GLUCOSE", value: "98", flag: nil, units: "mg/dL", range: "70 - 110", loinc: "2345-7" }, got[:tests].first)
    assert_equal "H", got[:tests].last[:flag]
    assert_equal [ " ", "Report Released Date/Time: NOV 01, 2026@09:00" ], got[:text]
    RpmsRpc::Lab.specimen(2, direction: :newer)
    assert_equal "-1", @client.calls.last[1][2]
  end

  def test_no_lab_data_is_nil_and_bad_input_sends_nothing
    use("ORWLRR INTERIMG" => [])
    assert_nil RpmsRpc::Lab.specimen(2)
    calls = @client.calls.size
    assert_nil RpmsRpc::Lab.specimen(2, direction: :sideways)
    assert_nil RpmsRpc::Lab.specimen("2^1")
    assert_equal calls, @client.calls.size
  end

  def test_cover_sheet_orders_read_the_orqor1_row
    use("BEHOLRCV LIST" => [ "^No orders found." ])
    assert_empty RpmsRpc::Lab.cover_sheet_orders(2)
    use("BEHOLRCV LIST" => [ "31^GLUCOSE BLOOD SERUM WC LB #42^3261101.08^PENDING" ])
    assert_equal [ { order_id: "31", text: "GLUCOSE BLOOD SERUM WC LB #42", start_at: Time.new(2026, 11, 1, 8, 0), status: "PENDING" } ],
                 RpmsRpc::Lab.cover_sheet_orders(2)
    use("BEHOLRCV LIST" => [ "^Error in date range." ])
    assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Lab.cover_sheet_orders(2) }
  end

  def test_the_medication_profile_reads_the_ihs_fields
    header = [ "~OP", "12R;O", "LISINOPRIL 10MG TAB", "", "3270101", "3", "", "", "41", "ACTIVE", "3261101", "30", "30",
               "1", "3261001", "100045", "7~PROVIDER,TEST", "", "", "PHARMACY", "HYPERTENSION", "", "", "00093-1111-01", "314076" ].join("^")
    use("BEHORXFN GETRXS" => [ header, " LISINOPRIL 10MG TAB  Qty: 30 for 30 days", "\\Sig: TAKE ONE TABLET BY MOUTH DAILY", "tchronic" ])
    rows = RpmsRpc::Medication.profile(2, days: 90)
    assert_equal [ "BEHORXFN GETRXS", [ "2", "90" ] ], @client.calls.last
    row = rows.first
    assert_equal [ "12R;O", "OP", "LISINOPRIL 10MG TAB", "ACTIVE", 41, "100045", "00093-1111-01", "314076", "HYPERTENSION", "30", "30", "3" ],
                 row.values_at(:order_id, :type, :name, :status, :order_ien, :prescription_number, :ndc, :rxnorm, :indication,
                               :days_supply, :quantity, :refills_remaining)
    assert_equal Date.new(2026, 11, 1), row[:last_filled]
    assert_equal Date.new(2026, 10, 1), row[:start_date]
    assert_equal [ "LISINOPRIL 10MG TAB  Qty: 30 for 30 days", "Sig: TAKE ONE TABLET BY MOUTH DAILY" ], row[:instructions]
    assert_equal [ "chronic" ], row[:comments]
  end

  def test_an_empty_profile_and_bad_input
    use("BEHORXFN GETRXS" => [])
    assert_empty RpmsRpc::Medication.profile(2)
    assert_empty RpmsRpc::Medication.profile(2, days: 0)
    assert_equal 1, @client.calls.size
    use("BEHORXFN GETRXS" => [ "-1^no" ])
    assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Medication.profile(2) }
  end
end
