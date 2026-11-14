# frozen_string_literal: true

require "minitest/autorun"
require "yaml"
require "rpms_rpc"
require "rpms_rpc/wire_capture"
require "rpms_rpc/retry_safety"
require "rpms_rpc/api/encounter"
require_relative "pilot_chart_reads_test"

# Issue #224 visit/encounter slice (#563): pilot wire evidence and CHKVISIT semantics.
class RpmsRpc::PilotVisitEncounterTest < Minitest::Test
  CHECKLIST_PATH = RpmsRpc::PilotChartReadsTest::CHECKLIST_PATH
  CHECKLIST_LINE = RpmsRpc::PilotChartReadsTest::CHECKLIST_LINE
  PINNED_RELEASE = RpmsRpc::PilotChartReadsTest::PINNED_RELEASE
  CHART_READ_PERSONA = RpmsRpc::PilotChartReadsTest::CHART_READ_PERSONA

  VISIT_ENCOUNTER_SLICE = [
    { rpc: "BEHOENCX GETVISIT", mapping: :encounter_visit, kind: "fields", inputs: [ "1" ] },
    { rpc: "BEHOENCX FETCH", mapping: :encounter_fetch, kind: "fields",
      inputs: [ "2", "6;3260825.09;A;1", "", "0" ] },
    { rpc: "BEHOENCX CHKVISIT", mapping: :encounter_chkvisit, kind: "fields", inputs: [ "1" ] }
  ].freeze

  WRITE_CHECKLIST_RPCS = [
    "BEHOENCX FETCH CREATE=1",
    "AMHG CREATE/EDIT VISIT"
  ].freeze

  LIVE_CHKVISIT_ROWS = [
    "POV^Visit has POV",
    "E&M^Visit has no note"
  ].freeze

  VISIT_BOOLEAN_ATTRIBUTES = { encounter_visit: [ :locked ], encounter_fetch: [ :locked ] }.freeze

  # Replays committed wire fixtures through Encounter.open (issue #563 test d).
  class VisitEncounterProbeClient
    def initialize(getvisit_rows, fetch_rows, chkvisit_rows)
      @getvisit_rows = getvisit_rows
      @fetch_rows = fetch_rows
      @chkvisit_rows = chkvisit_rows
    end

    def call_rpc(rpc, *)
      case rpc
      when "BEHOENCX GETVISIT"
        scalar_row!(@getvisit_rows)
      when "BEHOENCX FETCH"
        scalar_row!(@fetch_rows)
      when "BEHOENCX CHKVISIT"
        @chkvisit_rows
      else
        raise "unexpected RPC #{rpc}"
      end
    end

    private

    def scalar_row!(rows)
      raise "expected one data row, got #{rows.inspect}" unless rows.length == 1

      rows.first
    end
  end

  class << self
    def fixture_path_for(...) = RpmsRpc::PilotChartReadsTest.fixture_path_for(...)
    def catalog_entry_for(...) = RpmsRpc::PilotChartReadsTest.catalog_entry_for(...)
    def wire_contract_violations(...) = RpmsRpc::PilotChartReadsTest.wire_contract_violations(...)
    def unproven_attributes(...) = RpmsRpc::PilotChartReadsTest.unproven_attributes(...)
    def format_unproven_list(...) = RpmsRpc::PilotChartReadsTest.format_unproven_list(...)
    def normalize_cite(...) = RpmsRpc::PilotChartReadsTest.normalize_cite(...)
    def readiness_attribute_names(...) = RpmsRpc::PilotChartReadsTest.readiness_attribute_names(...)

    def locked_observed_both_ways?(mapping, fixture, attr)
      field = mapping.fields.find { |candidate| candidate.attribute == attr }
      return false unless field

      true_observed = false
      false_observed = false

      fixture.captured_data_rows.each do |raw_row|
        pieces = raw_row.to_s.split("^", -1)
        next unless pieces.length > field.position

        piece = pieces[field.position].to_s
        mapped = mapping.parse_many([ raw_row ]).first
        next if mapped.nil?

        true_observed = true if piece == "1" && mapped[attr] == true
        false_observed = true if piece == "0" && mapped[attr] == false
      end

      true_observed && false_observed
    end

    def visit_unproven_attributes(fixture)
      mapping = RpmsRpc::DataMapper[fixture.mapping_name]
      unproven = unproven_attributes(fixture).dup
      (VISIT_BOOLEAN_ATTRIBUTES[fixture.mapping_name] || []).each do |attr|
        next if locked_observed_both_ways?(mapping, fixture, attr)

        unproven << attr unless unproven.include?(attr)
      end
      unproven
    end

    def visit_expected_status(_slice, fixture)
      unproven = visit_unproven_attributes(fixture)
      mapping = RpmsRpc::DataMapper[fixture.mapping_name]
      all_readiness = readiness_attribute_names(mapping, fixture)
      if fixture.source == "no-data" || fixture.source == "routine-cite"
        "not-proven"
      elsif unproven.empty?
        "pilot-ready"
      elsif unproven.sort == all_readiness.sort
        "not-proven"
      else
        "partial"
      end
    end
  end

  def parse_checklist
    assert File.file?(CHECKLIST_PATH),
           "missing docs/pilot_rpc_readiness.md — visit/encounter pilot status must be written"

    rows = {}
    File.readlines(CHECKLIST_PATH, chomp: true).each_with_index do |line, idx|
      next if line.strip.empty? || line.lstrip.start_with?("#")

      m = CHECKLIST_LINE.match(line)
      unless m
        flunk "line #{idx + 1}: expected 'RPC | status | reason | unproven: …', got #{line.inspect}"
      end

      rpc = m[:rpc].strip
      rows[rpc] = {
        status: m[:status],
        reason: m[:reason].strip,
        unproven: m[:unproven].strip,
        line: idx + 1
      }
    end
    rows
  end

  def load_slice_fixture(slice)
    path = self.class.fixture_path_for(slice[:rpc])
    assert File.file?(path), "#{slice[:rpc]}: no fixture at #{path}"

    RpmsRpc::WireCapture::Fixture.load_file(path)
  end

  # Intent: WireCapture::CATALOG has a live entry per slice RPC with mapping, kind, and inputs.
  def test_catalog_has_live_entries_for_visit_encounter_reads
    failures = []
    VISIT_ENCOUNTER_SLICE.each do |slice|
      entry = self.class.catalog_entry_for(slice[:rpc])
      if entry.nil?
        failures << "#{slice[:rpc]}: no CatalogEntry in lib/rpms_rpc/wire_capture.rb"
        next
      end
      failures << "#{slice[:rpc]}: catalog mode #{entry.mode.inspect}, expected :live" unless entry.live?
      if entry.mapping != slice[:mapping]
        failures << "#{slice[:rpc]}: maps :#{entry.mapping}, expected :#{slice[:mapping]}"
      end
      if entry.kind != slice[:kind]
        failures << "#{slice[:rpc]}: kind #{entry.kind.inspect}, expected #{slice[:kind].inspect}"
      end
      if entry.inputs != slice[:inputs]
        failures << "#{slice[:rpc]}: inputs #{entry.inputs.inspect}, expected #{slice[:inputs].inspect}"
      end
    end
    assert_empty failures, "visit/encounter catalog gaps:\n  #{failures.join("\n  ")}"
  end

  # Intent: each slice RPC has a live-capture fixture stamped for PROV123 on the pinned build.
  def test_visit_encounter_fixtures_are_live_captures_on_the_pinned_build
    failures = []
    VISIT_ENCOUNTER_SLICE.each do |slice|
      fixture = load_slice_fixture(slice)
      entry = self.class.catalog_entry_for(slice[:rpc])
      refute_nil entry, "#{slice[:rpc]}: catalog entry required for cite check"

      failures << "#{slice[:rpc]}: source #{fixture.source.inspect}, expected live-capture" unless fixture.source == "live-capture"
      if fixture.release_tag != PINNED_RELEASE
        failures << "#{slice[:rpc]}: release_tag #{fixture.release_tag.inspect}, expected #{PINNED_RELEASE}"
      end
      data = YAML.safe_load_file(fixture.path)
      actual_persona = data["signed_on_as"]
      if actual_persona != CHART_READ_PERSONA
        failures << "#{slice[:rpc]}: signed_on_as #{actual_persona.inspect}, expected #{CHART_READ_PERSONA.inspect}"
      end
      if fixture.inputs != slice[:inputs]
        failures << "#{slice[:rpc]}: inputs #{fixture.inputs.inspect}, expected #{slice[:inputs].inspect}"
      end
      if fixture.captured_data_rows.empty?
        failures << "#{slice[:rpc]}: captured_data_rows must not be empty for live-capture proof"
      end
      fixture_cite = self.class.normalize_cite(fixture.cite)
      catalog_cite = self.class.normalize_cite(entry.cite)
      if fixture_cite != catalog_cite
        failures << "#{slice[:rpc]}: fixture cite differs from wire_capture catalog"
      end
      self.class.wire_contract_violations(fixture).each do |violation|
        failures << "#{slice[:rpc]}: #{violation}"
      end
    end
    assert_empty failures, failures.join("\n  ")
  end

  # Intent: CHKVISIT live reply on visit 1 is POV satisfied and E&M not checked (pinned capture).
  def test_chkvisit_fixture_matches_live_visit_one_reply
    slice = VISIT_ENCOUNTER_SLICE.find { |s| s[:rpc] == "BEHOENCX CHKVISIT" }
    fixture = load_slice_fixture(slice)
    assert_equal LIVE_CHKVISIT_ROWS.sort, fixture.captured_data_rows.sort,
                 "BEHOENCX CHKVISIT fixture must match live dispatch on visit 1"
  end

  # Intent: Encounter.open drops satisfied CHKVISIT rows; POV present on live capture stays out of missing_components.
  def test_open_replay_of_committed_fixtures_lists_only_em_as_missing
    getvisit = load_slice_fixture(VISIT_ENCOUNTER_SLICE[0])
    fetch = load_slice_fixture(VISIT_ENCOUNTER_SLICE[1])
    chkvisit = load_slice_fixture(VISIT_ENCOUNTER_SLICE[2])

    client = VisitEncounterProbeClient.new(
      getvisit.captured_data_rows,
      fetch.captured_data_rows,
      chkvisit.captured_data_rows
    )
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = client }
    result = RpmsRpc::Encounter.open(2, 1)
    refute_nil result, "Encounter.open(2, 1) should hydrate from the three fixtures"
    assert_equal 1, result[:visit_ien]
    assert_equal 2, result[:patient_dfn]
    assert_equal "DEMO PRIMARY CARE", result[:location]
    assert_equal [ { component: "E&M", message: "Visit has no note" } ], result[:missing_components]
  ensure
    RpmsRpc.reset!
  end

  # Intent: an empty CHKVISIT reply never reads as a complete visit (BEHOXQPC absent quits with no rows).
  def test_open_with_empty_chkvisit_reply_leaves_missing_components_unestablished
    getvisit = load_slice_fixture(VISIT_ENCOUNTER_SLICE[0])
    fetch = load_slice_fixture(VISIT_ENCOUNTER_SLICE[1])

    client = VisitEncounterProbeClient.new(
      getvisit.captured_data_rows,
      fetch.captured_data_rows,
      []
    )
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = client }
    result = RpmsRpc::Encounter.open(2, 1)
    refute_nil result, "Encounter.open(2, 1) should hydrate from GETVISIT and FETCH"
    assert_equal 1, result[:visit_ien]
    assert_equal 2, result[:patient_dfn]
    assert_nil result[:missing_components]
  ensure
    RpmsRpc.reset!
  end

  # Intent: retry_safety defines read as no FileMan file; CHKVISIT can file an alert via
  # SEND^BEHOXQPC -> ENTRY^XQALGUI (BEHOXQPC.m:64-74), whose "-4 Notification exists" dedupe
  # lasts only until the alert is processed or deleted.
  def test_encounter_open_is_non_idempotent_write_in_retry_safety_yml
    assert_equal :non_idempotent_write, RpmsRpc::RetrySafety.for(RpmsRpc::Encounter, :open)
    refute RpmsRpc::RetrySafety.auto_retry_safe?(RpmsRpc::Encounter, :open)
  end

  # Intent: checklist rows for read RPCs match fixture-derived status and unproven lists.
  def test_pilot_checklist_field_level_readiness_matches_visit_encounter_fixtures
    rows = parse_checklist
    failures = []
    VISIT_ENCOUNTER_SLICE.each do |slice|
      row = rows[slice[:rpc]]
      unless row
        failures << "#{slice[:rpc]}: missing checklist row"
        next
      end
      fixture = load_slice_fixture(slice)
      expected_unproven = self.class.format_unproven_list(self.class.visit_unproven_attributes(fixture))
      if row[:unproven] != expected_unproven
        failures << "#{slice[:rpc]} line #{row[:line]}: unproven #{row[:unproven].inspect}, " \
                     "expected #{expected_unproven.inspect}"
      end
      expected_status = self.class.visit_expected_status(slice, fixture)
      if row[:status] != expected_status
        failures << "#{slice[:rpc]} line #{row[:line]}: status #{row[:status].inspect}, " \
                     "expected #{expected_status.inspect}"
      end
      unless row[:reason].match?(/PROV123/)
        failures << "#{slice[:rpc]} line #{row[:line]}: reason must name persona PROV123"
      end
    end
    assert_empty failures, failures.join("\n  ")
  end

  # Intent: visit :locked is proven only when wire pieces "1" and "0" both map true/false (-1 or missing proves neither).
  def test_visit_locked_boolean_readiness_requires_one_and_zero_on_the_wire
    mapping = RpmsRpc::DataMapper[:encounter_visit]
    stub = Struct.new(:mapping_name, :source, :captured_data_rows, :path).new(
      :encounter_visit, "live-capture", [ "6^3260825.09^A^2^^0" ], nil
    )
    assert_includes self.class.visit_unproven_attributes(stub), :locked,
                    "locked 0 alone must stay unproven"

    both = Struct.new(:mapping_name, :source, :captured_data_rows, :path).new(
      :encounter_visit, "live-capture",
      [ "6^3260825.09^A^2^^1", "6^3260825.09^A^2^^0" ], nil
    )
    refute_includes self.class.visit_unproven_attributes(both), :locked,
                    "locked 1 and 0 together prove the boolean"

    one_and_sentinel = Struct.new(:mapping_name, :source, :captured_data_rows, :path).new(
      :encounter_visit, "live-capture",
      [ "6^3260825.09^A^2^^1", "6^3260825.09^A^2^^-1" ], nil
    )
    assert_includes self.class.visit_unproven_attributes(one_and_sentinel), :locked,
                    "locked 1 with -1 must not prove false"

    one_and_empty = Struct.new(:mapping_name, :source, :captured_data_rows, :path).new(
      :encounter_visit, "live-capture",
      [ "6^3260825.09^A^2^^1", "6^3260825.09^A^2^^" ], nil
    )
    assert_includes self.class.visit_unproven_attributes(one_and_empty), :locked,
                    "locked 1 with missing piece must not prove false"

    refute self.class.locked_observed_both_ways?(mapping, stub, :locked)
    assert self.class.locked_observed_both_ways?(mapping, both, :locked)
  end

  # Intent: write paths stay not-proven with named seed gaps (PROV123 division / AMHG activity type).
  def test_pilot_checklist_write_rows_document_seed_gaps
    rows = parse_checklist
    WRITE_CHECKLIST_RPCS.each do |rpc|
      refute_nil rows[rpc], "checklist must list #{rpc}"
    end

    fetch_row = rows["BEHOENCX FETCH CREATE=1"]
    assert_equal "not-proven", fetch_row[:status]
    assert_match(/PROV123/, fetch_row[:reason])
    assert_match(/TYPE OF VISIT MISSING/i, fetch_row[:reason])
    assert_match(/SYS123/, fetch_row[:reason])
    assert_includes fetch_row[:unproven], "visit_ien"

    amhg_row = rows["AMHG CREATE/EDIT VISIT"]
    assert_equal "not-proven", amhg_row[:status]
    assert_match(/PROV123/, amhg_row[:reason])
    assert_match(/Activity Type Missing/i, amhg_row[:reason])
    refute_equal "none", amhg_row[:unproven]
  end

  # Intent: the CREATE=1 row cites the live spec that pins the seed gap, names the blocker and
  # records the division-swap experiment; the pilot persona still cannot create (#721).
  def test_pilot_checklist_create_row_cites_the_live_spec_that_pins_the_seed_gap
    fetch_row = parse_checklist["BEHOENCX FETCH CREATE=1"]
    refute_nil fetch_row, "checklist must list BEHOENCX FETCH CREATE=1"
    assert_equal "not-proven", fetch_row[:status]
    assert_includes fetch_row[:unproven], "visit_ien"

    reason = fetch_row[:reason]
    assert_includes reason, "test/live/encounter_visit_live_test.rb",
                    "the row must cite the live spec that pins the cause, by path"
    assert_includes reason, "openrpms#1078", "the row must name the blocking seed issue"
    refute_match(/not pinned by a test/i, reason, "the cause is pinned by the live spec now")
    assert_match(/visit 111/, reason, "the row must record the division-swap experiment (it created visit 111)")
    assert_match(/GETVISIT/, reason, "the row must record that GETVISIT read the visit back in the experiment")
    assert_includes reason, "BEHOENCX.m:68", "the row must cite the source line that picks the visit type"
    assert_includes reason, 'DUZ("AG")', "the row must name the agency condition on the #9001000 path"
    assert_includes reason, "XUS1A.m:43", "the row must cite where broker sign-on sets DUZ(\"AG\")"
    refute_includes reason, "XUP.m:62", "broker sign-on sets DUZ(\"AG\") in DUZ^XUS1A, not XUP"
    assert_match(/observed/i, reason, "seed literals are observed on a date; only the relations are pinned")
    assert_match(/field \.04|\.04 TYPE OF VISIT/, reason, "the row must name the #9001000 field the create reads")
  end

  # Intent: no visit/encounter slice RPC is pilot-ready without a live capture that carries data rows.
  def test_no_visit_encounter_slice_rpc_is_pilot_ready_without_live_capture_rows
    rows = parse_checklist
    failures = []
    VISIT_ENCOUNTER_SLICE.each do |slice|
      row = rows[slice[:rpc]]
      next failures << "#{slice[:rpc]}: missing checklist row" unless row
      next unless row[:status] == "pilot-ready"

      fixture = load_slice_fixture(slice)
      unless fixture.source == "live-capture" && fixture.captured_data_rows.any?
        failures << "#{slice[:rpc]}: pilot-ready requires live-capture with data rows"
      end
    end
    assert_empty failures, failures.join("\n  ")
  end
end
