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

  # Default `rake wire:capture` sign-on (lib/tasks/wire.rake RPMS_ACCESS).
  WIRE_CAPTURE_DEFAULT_SIGNED_ON_AS = "SYS123"

  # BEHOPTCX.m FMTSSN always masks SSN as this literal — populated on the wire but not evidence.
  BEHOPTCX_FORCED_UNPROVEN = { patient_ptinfo: [ :ssn ] }.freeze

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
    (?<status>pilot-ready|partial|fails-live|not-proven)
    \s*\|\s*
    (?<reason>.+?)
    \s*\|\s*
    unproven:\s*
    (?<unproven>.+?)
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

    def mapped_attribute_names(mapping)
      if mapping.scalar?
        [ mapping.instance_variable_get(:@scalar_attribute) ].compact
      elsif mapping.text_blob?
        [ mapping.instance_variable_get(:@text_attribute) ].compact
      else
        mapping.fields.map(&:attribute)
      end
    end

    def forced_unproven?(mapping_name, attribute)
      BEHOPTCX_FORCED_UNPROVEN.fetch(mapping_name, []).include?(attribute)
    end

    def attribute_populated_in_capture?(mapping, fixture, attribute)
      if mapping.scalar?
        scalar = mapping.instance_variable_get(:@scalar_attribute)
        return false unless attribute == scalar

        fixture.captured_data_rows.any? { |row| !row.to_s.strip.empty? }
      elsif mapping.text_blob?
        blob = mapping.instance_variable_get(:@text_attribute)
        attribute == blob && fixture.captured_data_rows.any?
      else
        field = mapping.fields.find { |f| f.attribute == attribute }
        return false unless field

        fixture.captured_data_rows.any? do |row|
          piece = row.split("^", -1)[field.position]
          !piece.to_s.empty?
        end
      end
    end

    def unproven_attributes(fixture)
      mapping = RpmsRpc::DataMapper[fixture.mapping_name]
      names = mapped_attribute_names(mapping)
      return names if fixture.source == "no-data" || fixture.captured_data_rows.empty?

      names.select do |attribute|
        forced_unproven?(fixture.mapping_name, attribute) ||
          !attribute_populated_in_capture?(mapping, fixture, attribute)
      end
    end

    def format_unproven_list(attributes)
      attributes.empty? ? "none" : attributes.map(&:to_s).sort.join(", ")
    end

    def expected_checklist_status(slice, fixture)
      unproven = unproven_attributes(fixture)
      if slice[:rpc] == "ORQQPL LIST" && orqqpl_inactive_icd_mapping_leaks?
        "fails-live"
      elsif fixture.source == "no-data"
        "not-proven"
      elsif unproven.empty?
        "pilot-ready"
      else
        "partial"
      end
    end

    # Inactive ICD rows (ORQQPL.m:15-16) must not surface error text or "#" as icd_code / transcribed.
    def orqqpl_inactive_icd_mapping_leaks?
      path = fixture_path_for("ORQQPL LIST")
      return false unless File.file?(path)

      fixture = RpmsRpc::WireCapture::Fixture.load_file(path)
      fixture.captured_data_rows.any? do |row|
        pieces = row.split("^", -1)
        next false unless pieces[12] == "#"

        parsed = RpmsRpc::DataMapper[:problem_list].parse_many([ row ]).first
        next false if parsed.nil?

        parsed[:icd_code].to_s.include?("Invalid Code") || parsed[:transcribed] == "#"
      end
    end
  end

  def parse_checklist
    assert File.file?(CHECKLIST_PATH),
           "missing docs/pilot_rpc_readiness.md — chart-read pilot status must be written for humans and CI"

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
    skip "#{slice[:rpc]}: no fixture" unless File.file?(path)

    RpmsRpc::WireCapture::Fixture.load_file(path)
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

  # Replaces the old three-column pilot-ready|not-proven-only gate (#224 round-1):
  # checklist rows must carry field-level unproven lists and statuses derived from fixtures.
  def test_pilot_checklist_field_level_readiness_matches_committed_fixtures
    rows = parse_checklist
    failures = []
    CHART_READ_SLICE.each do |slice|
      row = rows[slice[:rpc]]
      next failures << "#{slice[:rpc]}: missing checklist row" unless row

      fixture = load_slice_fixture(slice)
      expected_unproven = self.class.format_unproven_list(self.class.unproven_attributes(fixture))
      if row[:unproven] != expected_unproven
        failures << "#{slice[:rpc]} line #{row[:line]}: unproven #{row[:unproven].inspect}, " \
                     "expected #{expected_unproven.inspect} from capture + mapping"
      end

      expected_status = self.class.expected_checklist_status(slice, fixture)
      if row[:status] != expected_status
        failures << "#{slice[:rpc]} line #{row[:line]}: status #{row[:status].inspect}, " \
                     "expected #{expected_status.inspect}"
      end
    end
    assert_empty failures, failures.join("\n  ")
  end

  # Intent: BEHOPTCX PTINFO :ssn is masked by FMTSSN — always listed unproven even when populated.
  def test_behoptcx_ptinfo_ssn_counts_as_unproven_despite_masked_wire_value
    slice = CHART_READ_SLICE.find { |s| s[:mapping] == :patient_ptinfo }
    fixture = load_slice_fixture(slice)
    unproven = self.class.unproven_attributes(fixture)
    assert_includes unproven, :ssn,
                    "BEHOPTCX PTINFO :ssn must stay unproven (FMTSSN masks as XXX-XX-XXXX)"
    rows = parse_checklist
    row = rows[slice[:rpc]]
    skip "checklist missing" unless row
    assert_includes row[:unproven], "ssn",
                    "checklist unproven column must list ssn for BEHOPTCX PTINFO"
    refute_equal "pilot-ready", row[:status],
                 "masked SSN prevents pilot-ready until the checklist documents partial readiness"
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

  # Intent: chart-read captures record the default rake wire:capture sign-on persona (provenance #224).
  def test_chart_read_slice_fixtures_record_wire_capture_default_signed_on_as
    failures = []
    CHART_READ_SLICE.each do |slice|
      path = self.class.fixture_path_for(slice[:rpc])
      next failures << "#{slice[:rpc]}: no fixture" unless File.file?(path)

      data = YAML.safe_load_file(path)
      actual = data["signed_on_as"]
      if actual != WIRE_CAPTURE_DEFAULT_SIGNED_ON_AS
        failures << "#{slice[:rpc]}: signed_on_as #{actual.inspect}, expected #{WIRE_CAPTURE_DEFAULT_SIGNED_ON_AS.inspect}"
      end
    end
    assert_empty failures, failures.join("\n  ")
  end

  # Intent: live-capture slice fixtures carry provenance stamped with the pinned release tag and seeded inputs.
  def test_live_capture_chart_reads_are_stamped_on_the_pinned_build
    failures = []
    CHART_READ_SLICE.each do |slice|
      fixture = load_slice_fixture(slice)
      next unless fixture.source == "live-capture"
      next if fixture.captured_data_rows.empty?

      failures << "#{slice[:rpc]}: source #{fixture.source.inspect}, expected live-capture" unless fixture.source == "live-capture"
      failures << "#{slice[:rpc]}: release_tag #{fixture.release_tag.inspect}, expected #{PINNED_RELEASE}" if fixture.release_tag != PINNED_RELEASE
      failures << "#{slice[:rpc]}: inputs #{fixture.inputs.inspect}, expected #{slice[:inputs].inspect}" if fixture.inputs != slice[:inputs]
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

  # Intent: slice no-data fixture headers must admit the live call returned no rows (not "no live call").
  def test_no_data_chart_read_fixture_headers_honest_about_empty_live_reply
    failures = []
    CHART_READ_SLICE.reject { |s| s[:expect_pilot_ready] }.each do |slice|
      path = self.class.fixture_path_for(slice[:rpc])
      next failures << "#{slice[:rpc]}: no fixture" unless File.file?(path)

      comments = File.readlines(path, chomp: true).take(5).select { |l| l.start_with?("#") }.join("\n")
      if comments.match?(/no live call/i)
        failures << "#{slice[:rpc]}: header must not deny the live call (#{path})"
      end
      unless comments.match?(/live call returned no data rows/i)
        failures << "#{slice[:rpc]}: header must say the live call returned no data rows (#{path})"
      end
    end
    assert_empty failures, failures.join("\n  ")
  end

  # ORQQPL LIST inactive-ICD branch (ORQQPL.m:15-16): piece 13 "#" rows must not map error text / "#".
  def test_orqqpl_list_inactive_icd_rows_map_nil_codes_and_flag_inactive_icd
    path = self.class.fixture_path_for("ORQQPL LIST")
    skip "fixture missing" unless File.file?(path)

    fixture = RpmsRpc::WireCapture::Fixture.load_file(path)
    inactive_row = fixture.captured_data_rows.find { |row| row.split("^", -1)[12] == "#" }
    refute_nil inactive_row, "committed orqqpl-list.yml must include an inactive-ICD row (piece 13 '#')"

    parsed = RpmsRpc::DataMapper[:problem_list].parse_many([ inactive_row ]).first
    refute_nil parsed
    assert_nil parsed[:icd_code],
               "inactive ICD branch must not expose $$ICDDX error text as icd_code (mapping leak)"
    assert_nil parsed[:transcribed],
               "inactive ICD branch must not expose '#' as transcribed"
    assert_equal true, parsed[:inactive_icd],
                  "inactive ICD rows must expose inactive_icd: true"

    normal = RpmsRpc::DataMapper[:problem_list].parse_many(
      [ "123^Hypertension^A^I10^3200101^3250301^^^^^" ]
    ).first
    assert_equal "I10", normal[:icd_code]
    refute normal[:inactive_icd], "active ICD rows must not set inactive_icd"
  end

  # Intent: capture-backed slice fixtures pass the same mapping↔wire checks as wire_contract_test.
  def test_capture_backed_chart_read_fixtures_pass_the_wire_contract
    failures = []
    CHART_READ_SLICE.each do |slice|
      fixture = load_slice_fixture(slice)
      next unless fixture.source == "live-capture"
      next if fixture.captured_data_rows.empty?

      self.class.wire_contract_violations(fixture).each do |violation|
        failures << "#{slice[:rpc]} (: #{slice[:mapping]}): #{violation}"
      end
    end
    assert_empty failures, "wire-contract violations on pilot chart reads:\n  #{failures.join("\n  ")}"
  end
end
