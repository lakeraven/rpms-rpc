# frozen_string_literal: true

require "minitest/autorun"
require "yaml"
require "rpms_rpc/live_summary"
require "rpms_rpc/wire_capture"
require "rpms_rpc/mappings"
require_relative "wire_contract_test"

# Issue #224 (chart reads slice): pilot-ready wire evidence on the pinned build.
#
# These tests are the SPEC — they fail until the implementer adds catalog entries,
# re-captures fixtures from live dispatch on synthetic seed patients (DFN 2 for
# chart data on bcer-9.0-20261012-e7923a4-ydb), and writes docs/pilot_rpc_readiness.md.
# See docs/WIRE_CONTRACTS.md and ADR 0008–0010.
class RpmsRpc::PilotChartReadsTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  LOCK_PATH = File.join(ROOT, "data/fingerprints/rpms-ops.lock.yml")
  CHECKLIST_PATH = File.join(ROOT, "docs/pilot_rpc_readiness.md")

  PINNED_RELEASE = RpmsRpc::LiveSummary.pinned_build(LOCK_PATH).freeze

  # Slice RPCs for patient chart reads (#218). :inputs are what the gem's public
  # API sends today (lib/rpms_rpc/api/* + DataMapper fetch params).
  CHART_READ_SLICE = [
    { rpc: "ORWPT ID INFO", mapping: :patient_id_info, kind: "fields",
      inputs: [ "2" ], expect_pilot_ready: true },
    { rpc: "BEHOPTCX PTINFO", mapping: :patient_ptinfo, kind: "fields",
      inputs: [ "2" ], expect_pilot_ready: true },
    { rpc: "BEHOPTPC GETBDP", mapping: :patient_designated_provider, kind: "fields",
      inputs: [ "2" ], expect_pilot_ready: false },
    { rpc: "BEHOCACV CWAD", mapping: :patient_cwad, kind: "scalar",
      inputs: [ "2" ], expect_pilot_ready: true },
    { rpc: "ORQQPL LIST", mapping: :problem_list, kind: "fields",
      inputs: [ "2", "" ], expect_pilot_ready: true },
    { rpc: "ORQQAL LIST", mapping: :allergy_list, kind: "fields",
      inputs: [ "2" ], expect_pilot_ready: true },
    { rpc: "ORWPS ACTIVE", mapping: :medication_active, kind: "text_blob",
      inputs: [ "2" ], expect_pilot_ready: false },
    { rpc: "ORQQVI VITALS", mapping: :vitals, kind: "fields",
      inputs: [ "2" ], expect_pilot_ready: true }
  ].freeze

  CHECKLIST_LINE = /
    \A
    (?<rpc>[^|]+?)
    \s*\|\s*
    (?<status>pilot-ready|not-proven)
    \s*\|\s*
    (?<reason>.+?)
    \z
  /x

  class << self
    def fixture_path_for(rpc)
      File.join(RpmsRpc::WireCapture::FIXTURES_DIR, "#{rpc.downcase.tr(" /", "--")}.yml")
    end

    def catalog_entry_for(rpc)
      RpmsRpc::WireCapture::CATALOG.find { |e| e.rpc == rpc }
    end

    # Reuses the wire-contract gate without duplicating its rules (issue #189).
    def wire_contract_violations(fixture)
      return [] if RpmsRpc::WireContractTest::KNOWN_DIVERGENCES.key?(fixture.mapping_name)

      mapping = RpmsRpc::DataMapper[fixture.mapping_name]
      RpmsRpc::WireCapture::Contract.check(mapping, fixture)
    end
  end

  def parse_checklist
    assert File.file?(CHECKLIST_PATH),
           "missing docs/pilot_rpc_readiness.md — chart-read pilot status must be written for humans and CI"

    rows = {}
    File.readlines(CHECKLIST_PATH, chomp: true).each_with_index do |line, idx|
      next if line.strip.empty? || line.lstrip.start_with?("#")

      m = CHECKLIST_LINE.match(line)
      flunk "line #{idx + 1}: expected 'RPC | pilot-ready|not-proven | reason', got #{line.inspect}" unless m

      rpc = m[:rpc].strip
      rows[rpc] = { status: m[:status], reason: m[:reason].strip, line: idx + 1 }
    end
    rows
  end

  def test_pinned_release_is_the_issue_224_build
    assert_equal "bcer-9.0-20261012-e7923a4-ydb", PINNED_RELEASE
  end

  # Intent: the pilot checklist exists and names every slice RPC with an explicit status.
  def test_pilot_checklist_covers_every_chart_read_rpc
    rows = parse_checklist
    missing = CHART_READ_SLICE.map { |s| s[:rpc] } - rows.keys
    assert_empty missing,
                 "docs/pilot_rpc_readiness.md must list every chart-read RPC (#{missing.join(", ")})"
  end

  # Intent: checklist status matches whether the pinned build can prove layout (no-data never pilot-ready).
  def test_pilot_checklist_status_matches_pinned_build_evidence
    rows = parse_checklist
    CHART_READ_SLICE.each do |slice|
      row = rows[slice[:rpc]]
      skip "checklist missing" unless row

      if slice[:expect_pilot_ready]
        assert_equal "pilot-ready", row[:status],
                     "#{slice[:rpc]} line #{row[:line]}: seeded chart data on #{PINNED_RELEASE} requires pilot-ready"
      else
        assert_equal "not-proven", row[:status],
                     "#{slice[:rpc]} line #{row[:line]}: no layout evidence on #{PINNED_RELEASE} — must be not-proven " \
                     "(#{row[:reason]})"
      end
    end
  end

  # Intent: WireCapture::CATALOG has a :live entry per slice RPC with API-accurate inputs (DFN 2, not registration-only 8).
  def test_catalog_has_live_entries_for_chart_reads_with_api_inputs
    failures = []
    CHART_READ_SLICE.each do |slice|
      entry = self.class.catalog_entry_for(slice[:rpc])
      if entry.nil?
        failures << "#{slice[:rpc]}: no CatalogEntry in lib/rpms_rpc/wire_capture.rb"
        next
      end
      failures << "#{slice[:rpc]}: catalog mode #{entry.mode.inspect}, expected :live" unless entry.live?
      failures << "#{slice[:rpc]}: maps :#{entry.mapping}, expected :#{slice[:mapping]}" if entry.mapping != slice[:mapping]
      failures << "#{slice[:rpc]}: kind #{entry.kind.inspect}, expected #{slice[:kind].inspect}" if entry.kind != slice[:kind]
      failures << "#{slice[:rpc]}: inputs #{entry.inputs.inspect}, expected #{slice[:inputs].inspect}" if entry.inputs != slice[:inputs]
    end
    assert_empty failures, "chart-read catalog gaps:\n  #{failures.join("\n  ")}"
  end

  # Intent: each slice RPC has a committed fixture at the path rake wire:capture uses.
  def test_each_chart_read_has_a_committed_wire_fixture
    missing = CHART_READ_SLICE.filter_map do |slice|
      path = self.class.fixture_path_for(slice[:rpc])
      File.basename(path) unless File.file?(path)
    end
    assert_empty missing,
                 "missing fixture(s) under test/fixtures/wire_captures/ — run rake wire:capture: #{missing.join(", ")}"
  end

  # Intent: pilot-ready RPCs carry live-capture provenance stamped with the pinned release tag and seeded inputs.
  def test_pilot_ready_chart_reads_are_live_capture_on_the_pinned_build
    rows = parse_checklist
    failures = []
    CHART_READ_SLICE.each do |slice|
      next unless slice[:expect_pilot_ready]
      next unless rows[slice[:rpc]]&.dig(:status) == "pilot-ready"

      path = self.class.fixture_path_for(slice[:rpc])
      next failures << "#{slice[:rpc]}: no fixture" unless File.file?(path)

      fixture = RpmsRpc::WireCapture::Fixture.load_file(path)
      failures << "#{slice[:rpc]}: source #{fixture.source.inspect}, expected live-capture" unless fixture.source == "live-capture"
      failures << "#{slice[:rpc]}: release_tag #{fixture.release_tag.inspect}, expected #{PINNED_RELEASE}" if fixture.release_tag != PINNED_RELEASE
      failures << "#{slice[:rpc]}: inputs #{fixture.inputs.inspect}, expected #{slice[:inputs].inspect}" if fixture.inputs != slice[:inputs]
      failures << "#{slice[:rpc]}: live-capture has no data rows — re-capture against DFN 2" if fixture.captured_data_rows.empty?
    end
    assert_empty failures, failures.join("\n  ")
  end

  # Intent: ORWPS ACTIVE and BEHOPTPC GETBDP stay honestly no-data; absence of data is never verification.
  def test_no_data_chart_reads_are_recorded_as_no_data_not_live_capture
    rows = parse_checklist
    failures = []
    CHART_READ_SLICE.each do |slice|
      next if slice[:expect_pilot_ready]

      path = self.class.fixture_path_for(slice[:rpc])
      next failures << "#{slice[:rpc]}: no fixture" unless File.file?(path)

      fixture = RpmsRpc::WireCapture::Fixture.load_file(path)
      failures << "#{slice[:rpc]}: must be source no-data on #{PINNED_RELEASE}, got #{fixture.source.inspect}" unless fixture.source == "no-data"
      failures << "#{slice[:rpc]}: release_tag #{fixture.release_tag.inspect}, expected #{PINNED_RELEASE}" if fixture.release_tag != PINNED_RELEASE
      failures << "#{slice[:rpc]}: no-data fixture must not carry data rows" if fixture.captured_data_rows.any?
      status = rows[slice[:rpc]]&.dig(:status)
      failures << "#{slice[:rpc]}: checklist must say not-proven, got #{status.inspect}" if status != "not-proven"
    end
    assert_empty failures, failures.join("\n  ")
  end

  # Intent: pilot-ready fixtures pass the same mapping↔wire checks as wire_contract_test (no duplicated rules).
  def test_pilot_ready_chart_read_fixtures_pass_the_wire_contract
    rows = parse_checklist
    failures = []
    CHART_READ_SLICE.each do |slice|
      next unless slice[:expect_pilot_ready]
      next unless rows[slice[:rpc]]&.dig(:status) == "pilot-ready"

      path = self.class.fixture_path_for(slice[:rpc])
      next unless File.file?(path)

      fixture = RpmsRpc::WireCapture::Fixture.load_file(path)
      self.class.wire_contract_violations(fixture).each do |violation|
        failures << "#{slice[:rpc]} (: #{slice[:mapping]}): #{violation}"
      end
    end
    assert_empty failures, "wire-contract violations on pilot chart reads:\n  #{failures.join("\n  ")}"
  end
end
