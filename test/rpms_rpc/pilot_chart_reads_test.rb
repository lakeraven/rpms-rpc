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

  # BEHOCACV CWAD letters → brief_header flags (patient.rb). Readiness treats each
  # letter as its own evidence slot (#224 round-2), not the scalar :cwad string alone.
  CWAD_LETTER_FLAGS = {
    "C" => :crisis_flag,
    "W" => :warning_flag,
    "A" => :allergy_flag,
    "D" => :ad_flag
  }.freeze

  # Mapped booleans are proven only when both true and false appear in mapped rows.
  BOOLEAN_MAPPED_ATTRIBUTES = { problem_list: [ :inactive_icd ] }.freeze

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

    def mapped_rows_for_fixture(mapping, fixture)
      if mapping.scalar?
        scalar = mapping.instance_variable_get(:@scalar_attribute)
        fixture.captured_data_rows.filter_map do |row|
          value = mapping.parse_scalar(row)
          next if value.nil? || value.to_s.empty?

          { scalar => value }
        end
      elsif mapping.text_blob?
        blob = mapping.instance_variable_get(:@text_attribute)
        text = mapping.parse_text(fixture.captured_data_rows)
        text.nil? || text.empty? ? [] : [ { blob => text } ]
      else
        mapping.parse_many(fixture.captured_data_rows)
      end
    end

    def mapped_value_present?(value)
      !value.nil? && !value.to_s.empty?
    end

    def attribute_populated_in_mapped_capture?(mapping, fixture, attribute)
      mapped_rows_for_fixture(mapping, fixture).any? do |row|
        mapped_value_present?(row[attribute])
      end
    end

    def boolean_values_observed_in_mapped_capture?(mapping, fixture, attribute)
      rows = mapped_rows_for_fixture(mapping, fixture)
      rows.any? { |row| row[attribute] == true } &&
        rows.any? { |row| row[attribute] == false }
    end

    def cwad_readiness_attributes
      CWAD_LETTER_FLAGS.values
    end

    def cwad_letter_observed_in_capture?(fixture, attribute)
      letter = CWAD_LETTER_FLAGS.key(attribute)
      return false unless letter

      fixture.captured_data_rows.any? { |row| row.to_s.include?(letter) }
    end

    def readiness_attribute_names(mapping, fixture)
      if fixture.mapping_name == :patient_cwad
        cwad_readiness_attributes
      else
        mapped_attribute_names(mapping)
      end
    end

    def unproven_attributes(fixture)
      mapping = RpmsRpc::DataMapper[fixture.mapping_name]
      names = readiness_attribute_names(mapping, fixture)
      return names if fixture.source == "no-data" || fixture.captured_data_rows.empty?

      boolean_attrs = BOOLEAN_MAPPED_ATTRIBUTES.fetch(fixture.mapping_name, [])

      names.select do |attribute|
        if fixture.mapping_name == :patient_cwad
          !cwad_letter_observed_in_capture?(fixture, attribute)
        elsif boolean_attrs.include?(attribute)
          !boolean_values_observed_in_mapped_capture?(mapping, fixture, attribute)
        else
          forced_unproven?(fixture.mapping_name, attribute) ||
            !attribute_populated_in_mapped_capture?(mapping, fixture, attribute)
        end
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

    # Round-2 SPEC: inactive_icd follows piece 13/9 "#" markers (ORQQPL.m:15-16),
    # not $$ICDDX error text in piece 4.
    def orqqpl_inactive_icd_mapping_leaks?
      path = fixture_path_for("ORQQPL LIST")
      return false unless File.file?(path)

      mapper = RpmsRpc::DataMapper[:problem_list]
      fixture = RpmsRpc::WireCapture::Fixture.load_file(path)
      fixture.captured_data_rows.any? do |row|
        pieces = row.split("^", -1)
        parsed = mapper.parse_many([ row ]).first
        next false if parsed.nil?

        markers = pieces[12] == "#" && pieces[8] == "#"
        inactive = parsed[:inactive_icd] == true
        next true if markers != inactive
        next true if inactive && (mapped_value_present?(parsed[:icd_code]) || mapped_value_present?(parsed[:transcribed]))
        next true if pieces[3].to_s.match?(/\AInvalid Code\b/) && !markers && mapped_value_present?(parsed[:icd_code])

        false
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

  # Intent: signed_on_as is live-call provenance only (#224 round-2) — never on routine-cite.
  def test_chart_read_live_and_no_data_fixtures_record_wire_capture_default_signed_on_as
    failures = []
    CHART_READ_SLICE.each do |slice|
      path = self.class.fixture_path_for(slice[:rpc])
      next failures << "#{slice[:rpc]}: no fixture" unless File.file?(path)

      data = YAML.safe_load_file(path)
      source = data["source"]
      next unless %w[live-capture no-data].include?(source)

      actual = data["signed_on_as"]
      if actual != WIRE_CAPTURE_DEFAULT_SIGNED_ON_AS
        failures << "#{slice[:rpc]} (#{source}): signed_on_as #{actual.inspect}, " \
                     "expected #{WIRE_CAPTURE_DEFAULT_SIGNED_ON_AS.inspect}"
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

  # ORQQPL LIST inactive-ICD (#224 round-2): markers on pieces 13 and 9, not error text.
  # Replaces round-1 pin that keyed inactive_icd off "Invalid Code" in piece 4.
  def test_orqqpl_list_inactive_icd_rows_map_nil_codes_and_flag_inactive_icd
    mapper = RpmsRpc::DataMapper[:problem_list]

    inactive_real_code =
      "3^Diabetes^A^250.00^3230410^3261012^^^#^^^ORQQPL DETAIL^#"
    parsed = mapper.parse_many([ inactive_real_code ]).first
    refute_nil parsed
    assert_equal true, parsed[:inactive_icd],
                 "piece 13/9 '#' markers must set inactive_icd even when piece 4 is a real inactive code"
    assert_nil parsed[:icd_code],
               "inactive ICD rows must not report piece 4 as icd_code (real code or error text)"
    assert_nil parsed[:transcribed],
               "inactive ICD rows must not expose '#' as transcribed"

    path = self.class.fixture_path_for("ORQQPL LIST")
    if File.file?(path)
      fixture = RpmsRpc::WireCapture::Fixture.load_file(path)
      inactive_row = fixture.captured_data_rows.find { |row| row.split("^", -1)[12] == "#" }
      refute_nil inactive_row, "committed orqqpl-list.yml must include an inactive-ICD row (piece 13 '#')"
      captured = mapper.parse_many([ inactive_row ]).first
      assert_equal true, captured[:inactive_icd]
      assert_nil captured[:icd_code]
      assert_nil captured[:transcribed]
    end

    error_without_markers =
      "99^Hypertension^A^Invalid Code (not found in the ICD-9-CM system)^3200101^3250301^^^^^"
    err_row = mapper.parse_many([ error_without_markers ]).first
    refute err_row[:inactive_icd], "error text without piece 13 '#' must not set inactive_icd"
    assert_nil err_row[:icd_code],
               "error text in piece 4 must never become icd_code when markers are absent"

    active = mapper.parse_many(
      [ "123^Hypertension^A^I10^3200101^3250301^NSC^SPEXP^Y^HIGH^^^^" ]
    ).first
    assert_equal "I10", active[:icd_code]
    assert_equal "Y", active[:transcribed]
    refute active[:inactive_icd], "active ICD rows must not set inactive_icd"
  end

  def test_orqqpl_list_committed_capture_icd_code_and_transcribed_unproven_after_mapping
    slice = CHART_READ_SLICE.find { |s| s[:rpc] == "ORQQPL LIST" }
    fixture = load_slice_fixture(slice)
    unproven = self.class.unproven_attributes(fixture)
    assert_includes unproven, :icd_code,
                    "both capture rows map to nil icd_code — raw piece 4 must not count as proven"
    assert_includes unproven, :transcribed,
                    "inactive-ICD after_row clears transcribed — mapped nil is unproven"
    assert_includes unproven, :inactive_icd,
                    "capture shows inactive_icd true only — false must be observed for proof"
  end

  def test_behocacv_cwad_committed_capture_readiness_is_partial_on_letter_flags
    slice = CHART_READ_SLICE.find { |s| s[:mapping] == :patient_cwad }
    fixture = load_slice_fixture(slice)
    unproven = self.class.unproven_attributes(fixture)
    assert_includes unproven, :crisis_flag, 'CWAD "A" does not prove C'
    assert_includes unproven, :warning_flag, 'CWAD "A" does not prove W'
    assert_includes unproven, :ad_flag, 'CWAD "A" does not prove D'
    refute_includes unproven, :allergy_flag, 'CWAD "A" proves allergy_flag'
    assert_equal "partial", self.class.expected_checklist_status(slice, fixture),
                 "letter-flag gaps must not read as pilot-ready"
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
