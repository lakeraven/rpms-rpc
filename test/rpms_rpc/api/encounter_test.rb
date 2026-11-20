# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc"
require "rpms_rpc/api/encounter"
require_relative "../captured_replies"

# Encounter.open (BEHOENCX GETVISIT, FETCH, CHKVISIT) and Encounter.create
# (FETCH with CREATE) replay the conversations recorded as PROVIDER,TEST on
# seed patient DFN 2, whose visit 1 is at DEMO PRIMARY CARE, #44 IEN 10
# (test/fixtures/captured_replies/encounter.yml, spec
# tools/captured_replies/encounter.rb). Each test checks the gem sent exactly
# the recorded calls. The round trips are test/live/encounter_visit_live_test.rb.
class EncounterTest < Minitest::Test
  SLUG = "encounter"
  DFN = 2
  CLINIC = 10
  AT = "3261110.0900"

  def teardown
    RpmsRpc.reset!
  end

  def replay(flow)
    @flow = flow
    @client = CapturedReplies::ReplayCiaClient.new(flow ? CapturedReplies.flow_script(SLUG, flow) : {})
    RpmsRpc.configure { |cfg| cfg.client = @client }
  end

  def sent = @client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params] ] }
  def assert_sent_as_recorded = assert_equal(CapturedReplies.flow_calls(SLUG, @flow), sent, @flow)

  def test_open_returns_hydrated_encounter_context
    replay("open")

    result = RpmsRpc::Encounter.open(DFN, 1)

    assert_equal 1, result[:visit_ien]
    assert_equal DFN, result[:patient_dfn]
    # Consumer keys, each from the piece that really carries it:
    assert_equal CLINIC, result[:location_ien]              # GETVISIT piece 1 (FETCH has no location IEN)
    assert_equal "DEMO PRIMARY CARE", result[:location]     # FETCH piece 1 LOCNAME
    assert_equal "DPC", result[:clinic_abbrev]              # FETCH piece 2 LOCABBR
    assert_equal "PROVIDER,TEST", result[:provider]         # FETCH piece 5 PROVNAME
    assert_equal 200, result[:provider_ien]                 # FETCH piece 4 PROVIEN
    assert_equal "3260825.09", result[:datetime_raw]        # GETVISIT piece 2 VDT
    assert_equal "A", result[:service_category]             # GETVISIT piece 3 SVC
    assert_equal "A", result[:status]                       # same piece, the name consumers already read
    assert_equal false, result[:locked]                     # GETVISIT piece 6 / FETCH piece 8
    refute result.key?(:ward), "no BEHOENCX reply carries a ward; the key was invented"
    assert_sent_as_recorded
  end

  # FETCH's real signature is FETCH(DATA,DFN,VSTR,PRV,CREATE) (BEHOENCX.m:32).
  # open() sends the DFN and the EXTENDED visit string built from GETVISIT —
  # LOC;VDT;SVC;VISITIEN — so VSTR2VIS resolves the visit by IEN
  # (BEHOENCX.m:107) and CREATE=0 never adds one.
  def test_open_sends_fetch_the_dfn_and_the_extended_visit_string_with_create_0
    replay("open")

    RpmsRpc::Encounter.open(DFN, 1)

    assert_equal [ [ "BEHOENCX GETVISIT", [ "1" ] ],
                   [ "BEHOENCX FETCH", [ "2", "10;3260825.09;A;1", "", "0" ] ],
                   [ "BEHOENCX CHKVISIT", [ "1" ] ] ], sent
  end

  # Visit 1 has a POV and no note: CHKVISIT answers both rows, and only the
  # E&M one is missing.
  def test_open_reports_missing_components
    replay("open")

    assert_equal [ { component: "E&M", message: "Visit has no note" } ],
                 RpmsRpc::Encounter.open(DFN, 1)[:missing_components]
  end

  def test_open_returns_nil_for_unknown_visit
    replay("open_unknown")

    assert_nil RpmsRpc::Encounter.open(DFN, 99_999_999)
    assert_sent_as_recorded
  end

  def test_open_returns_nil_for_nil_dfn_or_visit_ien
    replay(nil)

    assert_nil RpmsRpc::Encounter.open(nil, 1)
    assert_nil RpmsRpc::Encounter.open(DFN, nil)
    assert_empty sent
  end

  # Cross-patient guard: visit 1 belongs to DFN 2. A caller passing any other
  # DFN must not get the hydrated context, and FETCH is never sent.
  def test_open_returns_nil_when_visit_belongs_to_different_dfn
    replay("open_other_patient")

    assert_nil RpmsRpc::Encounter.open(3, 1)
    assert_sent_as_recorded
  end

  # visit_string accepts a Date as documented: a plain Date has no clock, so it
  # is a FileMan date. It used to raise NoMethodError (Date#hour is private),
  # found by a live read-API run against yotta-0921 (2026-09-23).
  def test_visit_string_formats_a_plain_date_as_a_fileman_date
    assert_equal "1;3260923;A", RpmsRpc::Encounter.visit_string(1, Date.new(2026, 9, 23), "A")
  end

  def test_visit_string_keeps_the_clock_of_a_time_or_datetime
    assert_equal "1;3260923.1430;A", RpmsRpc::Encounter.visit_string(1, Time.new(2026, 9, 23, 14, 30), "A")
    assert_equal "1;3260923.1430;A", RpmsRpc::Encounter.visit_string(1, DateTime.new(2026, 9, 23, 14, 30), "A")
  end

  def test_visit_string_passes_a_preformatted_fileman_string_through
    assert_equal "6;3260915.003;A", RpmsRpc::Encounter.visit_string(6, "3260915.003", "A")
  end

  # The EXTENDED visit string carries the visit IEN as a 4th piece; VSTR2VIS
  # reads it (BEHOENCX.m:107 "IEN=+$P(VSTR,\";\",4)") and skips the FNDVIS
  # date-window search when it is set.
  def test_visit_string_appends_the_visit_ien_when_given
    assert_equal "6;3260915.003;A;1", RpmsRpc::Encounter.visit_string(6, "3260915.003", "A", visit_ien: 1)
    assert_equal "6;3260915.003;A", RpmsRpc::Encounter.visit_string(6, "3260915.003", "A", visit_ien: nil)
  end

  # ===========================================================================
  # CREATE — visit get-or-create over BEHOENCX FETCH with the CREATE flag
  # (FETCH^BEHOENCX; GETVISIT is a pure fetch and never creates — openrpms
  # docs/REGISTRATION_RPC_CONTRACTS.md §3).
  # ===========================================================================

  def test_create_returns_visit_context_and_sends_fetch_params
    replay("create")

    result = RpmsRpc::Encounter.create(DFN, location_ien: CLINIC, datetime: AT, service_category: "A")

    assert result[:success]
    assert_equal 118, result[:visit_ien]
    assert_equal "DEMO PRIMARY CARE", result[:location_name]
    # DFN, VSTR "LOC;FM_DATETIME;SVC_CAT", PRV, CREATE=1 (if-not-found)
    assert_equal [ [ "BEHOENCX FETCH", [ "2", "10;3261110.0900;A", "", "1" ] ] ], sent
  end

  def test_create_with_create_0_finds_the_visit_already_on_file
    replay("create_found")

    result = RpmsRpc::Encounter.create(DFN, location_ien: CLINIC, datetime: AT, service_category: "A", create: 0)

    assert_equal 118, result[:visit_ien]
    assert_sent_as_recorded
  end

  def test_create_formats_a_time_and_passes_provider_and_create_flag
    replay("create")

    RpmsRpc::Encounter.create(DFN, location_ien: CLINIC, datetime: Time.new(2026, 11, 10, 9, 0),
                                   service_category: "A", provider_ien: 200, create: -1)

    assert_equal [ [ "BEHOENCX FETCH", [ "2", "10;3261110.0900;A", "200", "-1" ] ] ], sent
  end

  # FETCH files a visit at a #44 IEN that is not on file, and names no
  # location: the build does not refuse it.
  def test_create_at_a_location_not_on_file_is_what_fetch_answers
    replay("create_unknown_location")

    result = RpmsRpc::Encounter.create(DFN, location_ien: 999_999, datetime: AT, service_category: "A")

    assert result[:success]
    assert_equal 119, result[:visit_ien]
    assert_equal "", result[:location_name].to_s
    assert_sent_as_recorded
  end

  # === visit_string(location_ien, datetime, service_category) ===

  def test_visit_string_formats_a_date_without_a_time
    assert_equal "1608;3260924;A", RpmsRpc::Encounter.visit_string(1608, Date.new(2026, 9, 24), "A")
  end

  def test_visit_string_formats_a_time_to_the_minute
    assert_equal "1608;3260924.0930;A", RpmsRpc::Encounter.visit_string(1608, Time.new(2026, 9, 24, 9, 30, 15), "A")
  end

  def test_visit_string_formats_a_datetime_to_the_minute
    assert_equal "1608;3260924.1405;A",
                 RpmsRpc::Encounter.visit_string(1608, DateTime.new(2026, 9, 24, 14, 5, 0), "A")
  end

  def test_visit_string_passes_a_fileman_string_through
    assert_equal "1608;3260924.09;A", RpmsRpc::Encounter.visit_string(1608, "3260924.09", "A")
  end
end
