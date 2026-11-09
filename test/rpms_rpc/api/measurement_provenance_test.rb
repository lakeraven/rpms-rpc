# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/measurement"
require_relative "../captured_replies"

# The Measurement read/provenance composition:
#   BGOVMSR GET / BGOVMSR LAST  measurement rows with visit IEN
#                               (GET^BGOVMSR: BGOVMSR.m:41-77; LAST^BGOVMSR: BGOVMSR.m:3-35)
#   ORQQVI VITALS               newest per type (FASTVIT^ORQQVI)
#   BEHOENCX GETVISIT           visit service category, reply piece 3
#   DDR GETS ENTRY DATA         #9000010.01 field 2 (ENTERED IN ERROR) + 1201/.07 dates
#   BEHOVM2 VUNITS              "US unit^LO^HI^Metric unit^LO^HI"
#
# Every reply is the build's (test/fixtures/captured_replies/measurement-provenance.yml):
# each Measurement read run as PROFILE,MD on a throwaway container, recorded as a
# flow and replayed through CiaClient. Demo patient 4's vitals are measurements
# 5-10 on visit 6; setup marked measurement 7 (respiration) entered in error.
#
# Not captured, so not tested here: a reported (T, E) visit with a measurement
# (every such visit on the build is locked and holds none), a measurement whose
# visit cannot be read, and a refused or partial decoration read. Those paths
# were tested against replies written by hand, which ADR 0009 retires.
class MeasurementProvenanceTest < Minitest::Test
  SLUG = "measurement-provenance"
  Measurement = RpmsRpc::Measurement

  DFN = 4
  VISIT_IEN = 6
  TAKEN = Time.new(2026, 9, 11, 21, 34, 0)

  # Answers nil for every call, for the nil-reply path no capture holds.
  class NilReplyClient
    def call_rpc(*) = nil
  end

  def teardown
    RpmsRpc.reset!
  end

  def replay(script)
    client = CapturedReplies::ReplayCiaClient.new(script)
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def replay_flow(name) = replay(CapturedReplies.flow_script(SLUG, name))

  def sent(client) = client.calls.map { |c| [ c[:rpc], c[:params] ] }

  # ==========================================================================
  # Request construction: the frames are the ones the build answered
  # ==========================================================================

  def test_for_visit_sends_the_flow_the_build_answered
    client = replay_flow("for_visit")
    Measurement.for_visit(VISIT_IEN)

    assert_equal CapturedReplies.flow_calls(SLUG, "for_visit"), sent(client)
    # INP = "VISIT_IEN^FORMAT", format 0 = multiline (GET^BGOVMSR: BGOVMSR.m:44-48)
    assert_equal [ "BGOVMSR GET", [ "6^0" ] ], sent(client).first
    # One visit read for the visit all six rows share (memoised).
    assert_equal [ [ "BEHOENCX GETVISIT", [ "6" ] ] ], sent(client).select { |rpc, _| rpc == "BEHOENCX GETVISIT" }
    # FILE/IENS/FIELDS/FLAGS list param (GETSC^DDR2 + PARSE^DDR2)
    assert_includes sent(client),
                    [ "DDR GETS ENTRY DATA", [ { "FILE" => "9000010.01", "IENS" => "5,", "FIELDS" => "2;.07;1201", "FLAGS" => "IE" } ] ]
    assert_includes sent(client), [ "BEHOVM2 VUNITS", [ "TMP" ] ]
  end

  # INP = "DFN^TYPE;TYPE^VISIT" (LAST^BGOVMSR: BGOVMSR.m:9-15)
  def test_latest_sends_dfn_types_and_visit
    client = replay_flow("latest_types_visit")
    Measurement.latest(DFN, types: %w[BP WT], visit_ien: VISIT_IEN)

    assert_equal CapturedReplies.flow_calls(SLUG, "latest_types_visit"), sent(client)
    assert_equal [ "BGOVMSR LAST", [ "4^BP;WT^6" ] ], sent(client).first
  end

  def test_newest_by_type_dispatches_orqqvi_vitals_for_the_patient
    client = replay_flow("newest")
    Measurement.newest_by_type(DFN)

    assert_equal CapturedReplies.flow_calls(SLUG, "newest"), sent(client)
    assert_equal [ "ORQQVI VITALS", [ "4" ] ], sent(client).first
  end

  # F1/F2 FileMan bounds (FASTVIT^ORQQVI: ORQQVI.m:69-70,74-78)
  def test_newest_by_type_passes_fileman_range_bounds
    client = replay_flow("newest_range")
    Measurement.newest_by_type(DFN, start_date: Time.new(2026, 9, 1, 0, 0, 0), end_date: Time.new(2026, 9, 30, 23, 59, 0))

    assert_equal [ "ORQQVI VITALS", [ "4", "3260901.0000", "3260930.2359" ] ], sent(client).first
  end

  # ==========================================================================
  # Decorated result
  # ==========================================================================

  def test_for_visit_returns_provenance_decorated_measurements
    replay_flow("for_visit")

    rows = Measurement.for_visit(VISIT_IEN)

    assert_equal %w[TMP PU RS BP O2 PA], rows.map { |r| r[:type] }
    assert_equal [ 5, 6, 7, 8, 9, 10 ], rows.map { |r| r[:measurement_ien] }
    bp = rows.find { |r| r[:type] == "BP" }
    assert_equal "117/81", bp[:value]
    assert_equal "mmHg", bp[:units]
    assert_equal TAKEN, bp[:date]
    assert_equal :event, bp[:date_source]
    assert_equal VISIT_IEN, bp[:visit_ien]
    assert_equal "A", bp[:service_category]
    assert_equal :office, bp[:capture_mode]
    assert_equal false, bp[:entered_in_error]
    # BEHOVM2 VUNITS answers "^^^^^" for PA: no unit, not an empty string.
    assert_nil rows.find { |r| r[:type] == "PA" }[:units]
  end

  def test_for_visit_flags_the_entered_in_error_row
    replay_flow("for_visit")

    rows = Measurement.for_visit(VISIT_IEN)

    assert_equal [ 7 ], rows.select { |r| r[:entered_in_error] }.map { |r| r[:measurement_ien] }
  end

  def test_latest_returns_decorated_rows
    replay_flow("latest")

    rows = Measurement.latest(DFN)

    assert_equal %w[TMP BP PU RS PA], rows.map { |r| r[:type] }
    assert(rows.all? { |r| r[:capture_mode] == :office && r[:visit_ien] == VISIT_IEN })
    assert_equal true, rows.find { |r| r[:measurement_ien] == 7 }[:entered_in_error]
  end

  # ==========================================================================
  # Service-category -> capture-mode classification
  # (codes: PXRHS01.m:14-26; M from APCDEIN.m:85)
  # ==========================================================================

  def test_in_facility_codes_classify_as_office
    %w[A H I S O R D].each do |code|
      assert_equal :office, Measurement.capture_mode_for(code), "code #{code}"
    end
  end

  def test_remote_and_historical_codes_classify_as_reported
    %w[T M E C].each do |code|
      assert_equal :reported, Measurement.capture_mode_for(code), "code #{code}"
    end
  end

  def test_unrecognized_codes_classify_as_unknown
    [ "N", "X", "", nil, "ZZ", "9" ].each do |code|
      assert_equal :unknown, Measurement.capture_mode_for(code), "code #{code.inspect}"
    end
  end

  def test_capture_mode_normalizes_case_and_whitespace
    assert_equal :office,   Measurement.capture_mode_for(" a ")
    assert_equal :reported, Measurement.capture_mode_for("t")
  end

  # ==========================================================================
  # Guards: nothing reaches the wire
  # ==========================================================================

  def test_for_visit_rejects_invalid_visit_ien_without_rpc_call
    client = replay({})
    assert_equal [], Measurement.for_visit(nil)
    assert_equal [], Measurement.for_visit(0)
    assert_equal [], Measurement.for_visit("garbage")
    assert_empty client.calls
  end

  def test_latest_rejects_invalid_dfn_without_rpc_call
    client = replay({})
    assert_equal [], Measurement.latest(nil)
    assert_equal [], Measurement.latest(-3)
    assert_empty client.calls
  end

  def test_newest_by_type_rejects_invalid_dfn_without_rpc_call
    client = replay({})
    assert_equal [], Measurement.newest_by_type(nil)
    assert_equal [], Measurement.newest_by_type(-2)
    assert_empty client.calls
  end

  def test_find_rejects_invalid_ien_without_rpc_call
    client = replay({})
    assert_nil Measurement.find(nil)
    assert_nil Measurement.find(0)
    assert_nil Measurement.find("garbage")
    assert_empty client.calls
  end

  # ==========================================================================
  # Caret discipline on composed INP params
  # ==========================================================================

  # BGOVMSR LAST takes ONE caret-delimited INP param ("DFN^TYPES^VISIT_IEN"),
  # so any caret a caller supplies becomes an extra protocol piece; `types` is
  # exactly what a FHIR `Observation?code=` query parameter lands in. The
  # build's empty reply answers the frame.
  def test_latest_never_lets_a_caller_inject_extra_inp_pieces
    client = replay_flow("latest_none")
    Measurement.latest(26_664, types: [ "WT^INJECTED" ], visit_ien: "9^9^9")

    inp = client.calls.first[:params].first
    assert_equal 3, inp.split("^", -1).length, "INP must stay DFN^TYPES^VISIT_IEN, got #{inp.inspect}"
  end

  def test_latest_rejects_a_non_numeric_visit_ien
    client = replay_flow("latest_none")
    Measurement.latest(26_664, types: [ "WT" ], visit_ien: "12abc")

    refute_includes client.calls.first[:params].first, "abc", "a visit IEN is numeric or absent, never free text"
  end

  # Same hazard on the FASTVIT date bounds, which take the raw value through.
  def test_newest_by_type_never_lets_a_date_bound_inject_pieces
    client = replay_flow("newest_none")
    Measurement.newest_by_type(26_664, start_date: "3260101^X", end_date: "3260607")

    assert(client.calls.first[:params].none? { |p| p.to_s.include?("^") }, "no param may carry a caret")
  end

  # ==========================================================================
  # Empty and nil replies
  # ==========================================================================

  # An EMPTY reply is ambiguous (a visit with no measurements and a broker that
  # answered nothing look identical on the wire), so it reads as unknown: nil.
  # The build answers a visit no visit holds with an empty reply.
  def test_for_visit_returns_nil_for_the_builds_empty_reply
    replay_flow("for_visit_none")
    assert_nil Measurement.for_visit(999_999)
  end

  def test_latest_returns_nil_for_the_builds_empty_reply
    replay_flow("latest_none")
    assert_nil Measurement.latest(999_999)
  end

  def test_newest_by_type_returns_nil_for_the_builds_empty_reply
    replay_flow("newest_none")
    assert_nil Measurement.newest_by_type(999_999)
  end

  def test_for_visit_returns_nil_on_a_nil_broker_response
    RpmsRpc.configure { |cfg| cfg.client = NilReplyClient.new }
    assert_nil Measurement.for_visit(VISIT_IEN)
  end

  # ==========================================================================
  # By-IEN read (.find): DDR GETS ENTRY DATA on one V MEASUREMENT.
  #   .01 type   .02 patient DFN   .03 visit IEN   .04 value
  #   1201 event date/time   2 entered in error   .07 time entered
  # ==========================================================================

  CORE_FIELDS = ".01;.02;.03;.04;2;1201;.07"

  def test_find_returns_fully_decorated_measurement
    client = replay_flow("find_event")

    row = Measurement.find(8)

    assert_equal({ measurement_ien: 8, patient_dfn: DFN, type: "BP", value: "117/81", units: "mmHg",
                   date: TAKEN, date_source: :event, visit_ien: VISIT_IEN, service_category: "A",
                   capture_mode: :office, entered_in_error: false }, row)
    assert_equal [ "DDR GETS ENTRY DATA", [ { "FILE" => "9000010.01", "IENS" => "8,", "FIELDS" => CORE_FIELDS, "FLAGS" => "IE" } ] ],
                 sent(client).first
  end

  def test_find_flags_entered_in_error
    replay_flow("find_eie")

    row = Measurement.find(7)

    assert_equal "RS", row[:type]
    assert_equal true, row[:entered_in_error]
  end

  # 1201 EVENT DATE/TIME is the clinical taken time; when it is empty the
  # canonical fallback is the VISIT date (VMEA^BPXRMPX: BPXRMPX.m:60-64), never
  # .07 TIME ENTERED. Measurement 13's visit (13) is dated 3260716.09.
  def test_find_falls_back_to_the_visit_date_when_1201_is_empty
    replay_flow("find_visit_date")

    row = Measurement.find(13)

    assert_equal "HT", row[:type]
    assert_equal 990_001, row[:patient_dfn]
    assert_equal Time.new(2026, 7, 16, 9, 0, 0), row[:date]
    assert_equal :visit, row[:date_source]
  end

  # DDR answers an IEN no measurement holds with an error block: nil, not a row.
  def test_find_returns_nil_for_an_unknown_ien
    replay_flow("find_unknown")
    assert_nil Measurement.find(999_999_999)
  end

  # ==========================================================================
  # Newest-per-type (.newest_by_type): FASTVIT^ORQQVI returns at most one row
  # per type (`Q:OK` at ORQQVI.m:170-171); rows are decorated through the same
  # DDR/BEHOENCX/VUNITS graph.
  # ==========================================================================

  def test_newest_by_type_returns_decorated_rows_with_distinct_iens
    replay_flow("newest")

    rows = Measurement.newest_by_type(DFN)

    assert_equal [ 5, 6, 7, 8, 10, 9 ], rows.map { |r| r[:measurement_ien] }
    # Each row keeps ITS OWN type and unit.
    assert_equal %w[TMP PU RS BP PA O2], rows.map { |r| r[:type] }
    assert_equal [ "F", "/min", "/min", "mmHg", nil, "%" ], rows.map { |r| r[:units] }
    rows.each do |row|
      assert_equal DFN, row[:patient_dfn]
      assert_equal VISIT_IEN, row[:visit_ien]
      assert_equal :office, row[:capture_mode]
      assert_equal TAKEN, row[:date]
      assert_equal :event, row[:date_source]
    end
    assert_equal [ 7 ], rows.select { |r| r[:entered_in_error] }.map { |r| r[:measurement_ien] }
  end
end
