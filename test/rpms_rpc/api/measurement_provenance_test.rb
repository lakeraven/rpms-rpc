# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/version"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/measurement"

# Tests for the Measurement read/provenance composition:
#   BGOVMSR GET / BGOVMSR LAST  — measurement rows with visit IEN
#                                 (GET^BGOVMSR: BGOVMSR.m:41-77;
#                                  LAST^BGOVMSR: BGOVMSR.m:3-35)
#   BEHOENCX GETVISIT           — visit service category, reply piece 3
#                                 (GETVISIT^BEHOENCX: BEHOENCX.m:4-16)
#   DDR GETS ENTRY DATA         — #9000010.01 field 2 (ENTERED IN ERROR,
#                                 stored by EIE^BEHOVM2) + 1201/.07 dates
#   BEHOVM2 VUNITS              — "US unit^LO^HI^Metric unit^LO^HI"
# All wire fixtures are synthetic.
class MeasurementProvenanceTest < Minitest::Test
  Measurement = RpmsRpc::Measurement
  Ddr = RpmsRpc::DdrFileman

  DFN       = "26664"
  VISIT_IEN = 2090061
  MSR_IEN   = 4001

  # Broker stub returning one canned raw response for every RPC —
  # exercises nil/garbage paths MockClient can't produce.
  class RawResponseClient
    def initialize(response) = @response = response
    def supports?(*) = true
    def call_rpc(*) = @response
  end

  def teardown
    RpmsRpc.reset!
  end

  def stub_broker_response(response)
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = RawResponseClient.new(response) }
  end

  def ddr_key(measurement_ien)
    Ddr.gets_entry_param(file: "9000010.01", iens: "#{measurement_ien},",
                         fields: "2;.07;1201", flags: "IE").to_s
  end

  def seed_full_graph(service_category: "A", eie_internal: "0")
    RpmsRpc.mock! do |m|
      m.seed_keyed_collection(:visit_measurements, "#{VISIT_IEN}^0", [
        { type: "WT", value: "180", date_display: "JUN 07, 2026@14:30",
          measurement_ien: MSR_IEN, visit_ien: VISIT_IEN,
          provider_name: "DEMO,PROVIDER", locked: false }
      ])
      m.seed(:encounter_visit, VISIT_IEN.to_s, {
        location_ien: 1608, datetime_raw: "3260607.1430",
        service_category: service_category, patient_dfn: DFN.to_i,
        visit_id: "5150", locked: false
      })
      m.seed(:ddr_gets_entry_data, ddr_key(MSR_IEN), <<~REPLY.chomp)
        [Data]
        9000010.01^#{MSR_IEN}^2^#{eie_internal}^#{eie_internal == '1' ? 'YES' : ''}
        9000010.01^#{MSR_IEN}^.07^3260607.1430^JUN 07, 2026@14:30
        9000010.01^#{MSR_IEN}^1201^3260607.1430^JUN 07, 2026@14:30
      REPLY
      m.seed(:vital_units, "WT", {
        us_unit: "lb", us_low: "2", us_high: "999",
        metric_unit: "kg", metric_low: "1", metric_high: "453"
      })
      yield m if block_given?
    end
  end

  # ==========================================================================
  # Wire-shape parsing (rows as GET^BGOVMSR / LAST^BGOVMSR build them)
  # ==========================================================================

  # GET^BGOVMSR row (BGOVMSR.m:76):
  # TYPENM^VALUE^CDT(DATE)^VFIEN^VISIT^PROVIDER NAME^ISLOCKED
  def test_visit_measurements_mapping_parses_get_bgovmsr_row
    row = RpmsRpc::DataMapper[:visit_measurements]
          .parse_one("WT^180^JUN 07, 2026@14:30^4001^2090061^DEMO,PROVIDER^0")

    assert_equal "WT", row[:type]
    assert_equal "180", row[:value]
    assert_equal "JUN 07, 2026@14:30", row[:date_display]
    assert_equal 4001, row[:measurement_ien]
    assert_equal 2090061, row[:visit_ien]
    assert_equal "DEMO,PROVIDER", row[:provider_name]
    assert_equal false, row[:locked]
  end

  # LAST^BGOVMSR row (BGOVMSR.m:35):
  # TYPENM^VALUE^CDT(DATE)^IEN^VSIT^ISLOCKED
  def test_latest_measurements_mapping_parses_last_bgovmsr_row
    row = RpmsRpc::DataMapper[:latest_measurements]
          .parse_one("BP^120/80^JUN 07, 2026@14:30^4002^2090061^1")

    assert_equal "BP", row[:type]
    assert_equal "120/80", row[:value]
    assert_equal 4002, row[:measurement_ien]
    assert_equal 2090061, row[:visit_ien]
    assert_equal true, row[:locked]
  end

  # GETVISIT^BEHOENCX reply (BEHOENCX.m:4-16):
  # hosp loc^visit date^service category^dfn^visit id^locked
  def test_encounter_visit_mapping_reads_service_category_at_piece_3
    visit = RpmsRpc::DataMapper[:encounter_visit]
            .parse_one("1608^3260607.1430^T^26664^5150^0")

    assert_equal "T", visit[:service_category]
    assert_equal "T", visit[:status] # legacy alias, same position
    assert_equal 26664, visit[:patient_dfn]
    assert_equal "5150", visit[:visit_id]
    assert_equal false, visit[:locked]
  end

  # Legacy seeds that only set :status must still round-trip — the unseeded
  # :service_category alias may not blank the position (format_one guard).
  def test_encounter_visit_status_only_seed_round_trips_service_category
    wire = RpmsRpc::DataMapper[:encounter_visit].format_one(
      { location_ien: 1608, datetime_raw: "3260607.1430", status: "A",
        patient_dfn: 26664, ward: "5150" }
    )
    parsed = RpmsRpc::DataMapper[:encounter_visit].parse_one(wire)

    assert_equal "A", parsed[:status]
    assert_equal "A", parsed[:service_category]
  end

  # ==========================================================================
  # Request construction
  # ==========================================================================

  def test_for_visit_dispatches_bgovmsr_get_with_visit_ien_and_multiline_format
    seed_full_graph
    Measurement.for_visit(VISIT_IEN)

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BGOVMSR GET" }
    refute_nil call
    # INP = "VISIT_IEN^FORMAT", format 0 = multiline (GET^BGOVMSR: BGOVMSR.m:44-48)
    assert_equal [ "#{VISIT_IEN}^0" ], call[:params]
  end

  def test_latest_dispatches_bgovmsr_last_with_dfn_types_visit
    RpmsRpc.mock!
    Measurement.latest(DFN, types: %w[HT WT], visit_ien: VISIT_IEN)

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BGOVMSR LAST" }
    refute_nil call
    # INP = "DFN^TYPE;TYPE^VISIT" (LAST^BGOVMSR: BGOVMSR.m:9-15)
    assert_equal [ "#{DFN}^HT;WT^#{VISIT_IEN}" ], call[:params]
  end

  def test_for_visit_resolves_service_category_via_behoencx_getvisit
    seed_full_graph
    Measurement.for_visit(VISIT_IEN)

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BEHOENCX GETVISIT" }
    refute_nil call
    assert_equal [ VISIT_IEN.to_s ], call[:params]
  end

  def test_for_visit_reads_eie_and_dates_via_ddr_gets_entry_data
    seed_full_graph
    Measurement.for_visit(VISIT_IEN)

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "DDR GETS ENTRY DATA" }
    refute_nil call
    # FILE/IENS/FIELDS/FLAGS list param (GETSC^DDR2 + PARSE^DDR2)
    assert_equal(
      { "FILE" => "9000010.01", "IENS" => "#{MSR_IEN},",
        "FIELDS" => "2;.07;1201", "FLAGS" => "IE" },
      call[:params].first
    )
  end

  def test_for_visit_resolves_units_via_behovm2_vunits
    seed_full_graph
    Measurement.for_visit(VISIT_IEN)

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BEHOVM2 VUNITS" }
    refute_nil call
    assert_equal [ "WT" ], call[:params]
  end

  # ==========================================================================
  # Decorated result
  # ==========================================================================

  def test_for_visit_returns_provenance_decorated_measurement
    seed_full_graph(service_category: "A", eie_internal: "0")
    rows = Measurement.for_visit(VISIT_IEN)

    assert_equal 1, rows.length
    row = rows.first
    assert_equal "WT",  row[:type]
    assert_equal "180", row[:value]
    assert_equal "lb",  row[:units]
    assert_equal Time.new(2026, 6, 7, 14, 30, 0), row[:date]
    assert_equal MSR_IEN,   row[:measurement_ien]
    assert_equal VISIT_IEN, row[:visit_ien]
    assert_equal "A",       row[:service_category]
    assert_equal :office,   row[:capture_mode]
    assert_equal false,     row[:entered_in_error]
  end

  def test_for_visit_flags_entered_in_error_row
    seed_full_graph(eie_internal: "1")
    assert_equal true, Measurement.for_visit(VISIT_IEN).first[:entered_in_error]
  end

  def test_for_visit_telecom_visit_is_reported
    seed_full_graph(service_category: "T")
    row = Measurement.for_visit(VISIT_IEN).first

    assert_equal "T", row[:service_category]
    assert_equal :reported, row[:capture_mode]
  end

  def test_latest_returns_decorated_rows
    RpmsRpc.mock! do |m|
      m.seed_keyed_collection(:latest_measurements, "#{DFN}^^", [
        { type: "WT", value: "180", date_display: "JUN 07, 2026@14:30",
          measurement_ien: MSR_IEN, visit_ien: VISIT_IEN, locked: false }
      ])
      m.seed(:encounter_visit, VISIT_IEN.to_s, {
        location_ien: 1608, datetime_raw: "3260607.1430",
        service_category: "E", patient_dfn: DFN.to_i, visit_id: "5150", locked: false
      })
      m.seed(:vital_units, "WT", { us_unit: "lb", metric_unit: "kg" })
    end

    rows = Measurement.latest(DFN)
    assert_equal 1, rows.length
    assert_equal "E", rows.first[:service_category]
    assert_equal :reported, rows.first[:capture_mode] # EVENT (HISTORICAL)
    # No DDR seed → EIE state unknown, never fabricated
    assert_nil rows.first[:entered_in_error]
  end

  # ==========================================================================
  # Service-category → capture-mode classification
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
  # Robustness — nil / garbage / partial graph
  # ==========================================================================

  def test_for_visit_rejects_invalid_visit_ien_without_rpc_call
    RpmsRpc.mock!
    assert_equal [], Measurement.for_visit(nil)
    assert_equal [], Measurement.for_visit(0)
    assert_equal [], Measurement.for_visit("garbage")
    assert_empty RpmsRpc.client.received_calls
  end

  def test_latest_rejects_invalid_dfn_without_rpc_call
    RpmsRpc.mock!
    assert_equal [], Measurement.latest(nil)
    assert_equal [], Measurement.latest(-3)
    assert_empty RpmsRpc.client.received_calls
  end

  def test_for_visit_returns_empty_for_unknown_visit
    RpmsRpc.mock!
    assert_equal [], Measurement.for_visit(999_999_999)
  end

  def test_for_visit_survives_broker_error_string
    stub_broker_response("-1^Application context has not been created!")
    assert_equal [], Measurement.for_visit(VISIT_IEN)
  end

  def test_for_visit_survives_nil_broker_response
    stub_broker_response(nil)
    assert_equal [], Measurement.for_visit(VISIT_IEN)
  end

  def test_missing_visit_read_degrades_to_unknown_capture_mode
    # Only the measurement list is reachable — no visit / DDR / units seeds
    RpmsRpc.mock! do |m|
      m.seed_keyed_collection(:visit_measurements, "#{VISIT_IEN}^0", [
        { type: "WT", value: "180", measurement_ien: MSR_IEN, visit_ien: VISIT_IEN }
      ])
    end

    row = Measurement.for_visit(VISIT_IEN).first
    assert_nil row[:service_category]
    assert_equal :unknown, row[:capture_mode]
    assert_nil row[:entered_in_error]
    assert_nil row[:units]
    assert_nil row[:date]
  end

  def test_rows_missing_iens_parse_without_decoration_calls_exploding
    RpmsRpc.mock! do |m|
      m.seed_keyed_collection(:visit_measurements, "#{VISIT_IEN}^0", [
        { type: "WT", value: "180" } # no measurement_ien / visit_ien
      ])
    end

    row = Measurement.for_visit(VISIT_IEN).first
    assert_equal "WT", row[:type]
    assert_nil row[:entered_in_error]
    assert_nil row[:service_category]
  end

  # ==========================================================================
  # By-IEN read (.find) — DDR GETS ENTRY DATA on one V MEASUREMENT.
  # Field numbers cited from corpus readers of #9000010.01:
  #   .01 type (pointer whose external is the abbreviation — BEHOVM2.m:65-66)
  #   .02 patient DFN (APCDBMI.m:20)   .03 visit IEN (APCDBMI.m:22, BHSMEA.m:87)
  #   .04 value + 1201 event d/t + 2 EIE (BTIUPCC4.m:19 reads ".03;.04;1201;2")
  # ==========================================================================

  CORE_FIELDS = ".01;.02;.03;.04;2;1201;.07"

  def core_ddr_key(measurement_ien)
    Ddr.gets_entry_param(file: "9000010.01", iens: "#{measurement_ien},",
                         fields: CORE_FIELDS, flags: "IE").to_s
  end

  def seed_core_reply(m, ien, type: "WT", dfn: DFN, visit: VISIT_IEN, value: "180", eie: "0",
                      include_1201: true, include_07: true)
    lines = [ "[Data]",
              "9000010.01^#{ien}^.01^12^#{type}",
              "9000010.01^#{ien}^.02^#{dfn}^DEMO,PATIENT",
              "9000010.01^#{ien}^.03^#{visit}^JUN 07, 2026@14:30",
              "9000010.01^#{ien}^.04^#{value}^#{value}",
              "9000010.01^#{ien}^2^#{eie}^#{eie == '1' ? 'YES' : ''}" ]
    lines << if include_1201
      "9000010.01^#{ien}^1201^3260607.1430^JUN 07, 2026@14:30"
    else
      "9000010.01^#{ien}^1201^^" # on file, no value — clinical time not recorded
    end
    lines << "9000010.01^#{ien}^.07^3260607^JUN 07, 2026" if include_07
    m.seed(:ddr_gets_entry_data, core_ddr_key(ien), lines.join("\n"))
  end

  def seed_visit_and_units(m, service_category: "A")
    m.seed(:encounter_visit, VISIT_IEN.to_s, {
      location_ien: 1608, datetime_raw: "3260607.1430",
      service_category: service_category, patient_dfn: DFN.to_i,
      visit_id: "5150", locked: false
    })
    m.seed(:vital_units, "WT", { us_unit: "lb", metric_unit: "kg" })
  end

  def test_find_returns_fully_decorated_measurement
    RpmsRpc.mock! do |m|
      seed_core_reply(m, MSR_IEN)
      seed_visit_and_units(m, service_category: "A")
    end

    row = Measurement.find(MSR_IEN)
    refute_nil row
    assert_equal MSR_IEN,   row[:measurement_ien]
    assert_equal DFN.to_i,  row[:patient_dfn]
    assert_equal "WT",      row[:type]
    assert_equal "180",     row[:value]
    assert_equal "lb",      row[:units]
    assert_equal Time.new(2026, 6, 7, 14, 30, 0), row[:date]
    assert_equal :event,    row[:date_source]
    assert_equal VISIT_IEN, row[:visit_ien]
    assert_equal "A",       row[:service_category]
    assert_equal :office,   row[:capture_mode]
    assert_equal false,     row[:entered_in_error]
  end

  def test_find_flags_entered_in_error
    RpmsRpc.mock! do |m|
      seed_core_reply(m, MSR_IEN, eie: "1")
      seed_visit_and_units(m)
    end

    assert_equal true, Measurement.find(MSR_IEN)[:entered_in_error]
  end

  def test_find_returns_nil_for_invalid_or_unknown_ien
    RpmsRpc.mock!
    assert_nil Measurement.find(nil)
    assert_nil Measurement.find(0)
    assert_nil Measurement.find("garbage")
    assert_nil Measurement.find(999_999_999) # unseeded → no DDR reply
  end

  def test_find_survives_broker_error_string
    stub_broker_response("-1^Application context has not been created!")
    assert_nil Measurement.find(MSR_IEN)
  end

  # ==========================================================================
  # Newest-per-type (.newest_by_type) — the registered "ORQQVI VITALS"
  # dispatches to FASTVIT^ORQQVI (.broker_dumps_8994_20260607.txt:565),
  # newest measurement per vital type in range (ORQQVI.m:64-91). This
  # replaced a `.history` method whose full-history claim was false —
  # FASTVIT returns at most one row per type (`Q:OK` at ORQQVI.m:170-171).
  # Rows are decorated via the same DDR/BEHOENCX/VUNITS graph.
  # ==========================================================================

  def seed_newest_graph(service_category: "A")
    RpmsRpc.mock! do |m|
      m.seed_keyed_collection(:vitals, DFN, [
        { measurement_ien: MSR_IEN,     type: "WT", value: "180", recorded_date: Time.new(2026, 6, 7, 14, 30, 0) },
        { measurement_ien: MSR_IEN + 1, type: "BP", value: "120/80", recorded_date: Time.new(2026, 6, 7, 14, 30, 0) }
      ])
      seed_core_reply(m, MSR_IEN)
      seed_core_reply(m, MSR_IEN + 1, value: "120/80")
      seed_visit_and_units(m, service_category: service_category)
      yield m if block_given?
    end
  end

  def test_newest_by_type_dispatches_orqqvi_vitals_for_the_patient
    seed_newest_graph
    Measurement.newest_by_type(DFN)

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORQQVI VITALS" }
    refute_nil call
    assert_equal [ DFN ], call[:params]
  end

  def test_newest_by_type_passes_fileman_range_bounds
    seed_newest_graph
    Measurement.newest_by_type(DFN, start_date: Time.new(2026, 1, 1, 0, 0, 0),
                                    end_date: Time.new(2026, 6, 30, 23, 59, 0))

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORQQVI VITALS" }
    refute_nil call
    # F1/F2 FileMan bounds (FASTVIT^ORQQVI: ORQQVI.m:69-70,74-78)
    assert_equal [ DFN, "3260101.0000", "3260630.2359" ], call[:params]
  end

  def test_newest_by_type_returns_decorated_rows_with_distinct_iens
    seed_newest_graph
    rows = Measurement.newest_by_type(DFN)

    assert_equal 2, rows.length
    assert_equal [ MSR_IEN, MSR_IEN + 1 ], rows.map { |r| r[:measurement_ien] }
    rows.each do |row|
      assert_equal "WT",      row[:type] # DDR .01 external wins over the wire code
      assert_equal "lb",      row[:units]
      assert_equal DFN.to_i,  row[:patient_dfn]
      assert_equal VISIT_IEN, row[:visit_ien]
      assert_equal "A",       row[:service_category]
      assert_equal :office,   row[:capture_mode]
      assert_equal false,     row[:entered_in_error]
      assert_equal Time.new(2026, 6, 7, 14, 30, 0), row[:date]
      assert_equal :event,    row[:date_source]
    end
    assert_equal rows.map { |r| r[:measurement_ien] }.uniq.length, rows.length
  end

  def test_newest_by_type_classifies_reported_capture_mode
    seed_newest_graph(service_category: "T")
    rows = Measurement.newest_by_type(DFN)

    assert(rows.all? { |r| r[:capture_mode] == :reported })
  end

  def test_newest_by_type_degrades_to_unknown_when_decoration_unreachable
    # Only the ORQQVI index is reachable — no DDR / visit / units seeds.
    RpmsRpc.mock! do |m|
      m.seed_keyed_collection(:vitals, DFN, [
        { measurement_ien: MSR_IEN, type: "WT", value: "180", recorded_date: Time.new(2026, 6, 7, 14, 30, 0) }
      ])
    end

    row = Measurement.newest_by_type(DFN).first
    assert_equal "WT", row[:type] # falls back to the FASTVIT type code
    assert_equal "180", row[:value]
    assert_nil row[:visit_ien]
    assert_nil row[:service_category]
    assert_equal :unknown, row[:capture_mode]
    assert_nil row[:entered_in_error] # unknown, never fabricated
    assert_nil row[:units]
    # The wire datetime survives, labeled as coming off the RPC wire
    # (server-side it is 1201-else-visit — VMEA^BPXRMPX: BPXRMPX.m:60-64).
    assert_equal Time.new(2026, 6, 7, 14, 30, 0), row[:date]
    assert_equal :wire, row[:date_source]
  end

  def test_newest_by_type_drops_rows_without_measurement_ien
    stub_broker_response("^No vitals found.")
    assert_equal [], Measurement.newest_by_type(DFN)
  end

  def test_newest_by_type_rejects_invalid_dfn_without_rpc_call
    RpmsRpc.mock!
    assert_equal [], Measurement.newest_by_type(nil)
    assert_equal [], Measurement.newest_by_type(-2)
    assert_empty RpmsRpc.client.received_calls
  end

  # ==========================================================================
  # Clinical-date provenance (:date_source) — 1201 EVENT DATE/TIME is the
  # clinical taken time (SAVE^BEHOENPC: BEHOENPC.m:275,286); when it is
  # empty the canonical fallback is the VISIT date (VMEA^BPXRMPX:
  # BPXRMPX.m:60-64); .07 is TIME ENTERED, an administrative timestamp
  # (BEHOENPC.m:274,287; BPXRMPX.m:70) — surfaced only labeled :entered,
  # never silently substituted for the clinical time.
  # ==========================================================================

  def seed_find_graph(include_1201: true, include_07: true, visit_seeded: true)
    RpmsRpc.mock! do |m|
      seed_core_reply(m, MSR_IEN, include_1201: include_1201, include_07: include_07)
      seed_visit_and_units(m) if visit_seeded
    end
  end

  def test_find_date_source_is_event_when_1201_present
    seed_find_graph
    row = Measurement.find(MSR_IEN)

    assert_equal Time.new(2026, 6, 7, 14, 30, 0), row[:date]
    assert_equal :event, row[:date_source]
  end

  def test_find_falls_back_to_visit_date_when_1201_missing
    seed_find_graph(include_1201: false)
    row = Measurement.find(MSR_IEN)

    # Visit datetime_raw "3260607.1430" (#9000010 .01 via BEHOENCX GETVISIT)
    assert_equal Time.new(2026, 6, 7, 14, 30, 0), row[:date]
    assert_equal :visit, row[:date_source]
  end

  def test_find_surfaces_entered_time_only_as_labeled_last_resort
    seed_find_graph(include_1201: false, visit_seeded: false)
    row = Measurement.find(MSR_IEN)

    # .07 fixture is date-only ("3260607") → midnight Time, labeled :entered
    assert_equal Time.new(2026, 6, 7), row[:date]
    assert_equal :entered, row[:date_source]
  end

  def test_find_has_nil_date_and_source_when_no_date_recoverable
    seed_find_graph(include_1201: false, include_07: false, visit_seeded: false)
    row = Measurement.find(MSR_IEN)

    assert_nil row[:date]
    assert_nil row[:date_source]
  end

  # ==========================================================================
  # DDR reply degradation — a broker error string that doesn't match the
  # FILE^IENS^FIELD grammar must degrade to UNKNOWN (nil), never fabricate
  # entered_in_error: false (Copilot finding on gets_entry).
  # ==========================================================================

  def test_for_visit_ddr_error_string_degrades_eie_to_unknown
    RpmsRpc.mock! do |m|
      m.seed_keyed_collection(:visit_measurements, "#{VISIT_IEN}^0", [
        { type: "WT", value: "180", measurement_ien: MSR_IEN, visit_ien: VISIT_IEN }
      ])
      m.seed(:ddr_gets_entry_data, ddr_key(MSR_IEN),
             "-1^Remote procedure DDR GETS ENTRY DATA failed")
      seed_visit_and_units(m)
    end

    row = Measurement.for_visit(VISIT_IEN).first
    assert_nil row[:entered_in_error]
    assert_nil row[:date]
    assert_nil row[:date_source]
  end
end
