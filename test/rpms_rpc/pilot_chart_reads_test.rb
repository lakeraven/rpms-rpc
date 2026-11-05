# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "yaml"
require "rpms_rpc"
require "rpms_rpc/live_summary"
require "rpms_rpc/wire_capture"
require "rpms_rpc/mappings"
require "rpms_rpc/api/medication"
require "rpms_rpc/api/patient"
require_relative "wire_contract_test"

# Issue #224 (chart reads slice): pilot-ready wire evidence on the pinned build.
#
# Grading (expected_checklist_status): live-capture with every readiness field still
# unproven is not-proven, not partial; partial means some but not all fields proven.
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

  # Clinician pilot persona (README least-privilege). Replaces round-2 rule that
  # chart-read slice fixtures were stamped signed_on_as SYS123.
  CHART_READ_PERSONA = "PROV123"

  # BEHOPTCX.m FMTSSN always masks SSN as this literal — populated on the wire but not evidence.
  BEHOPTCX_FORCED_UNPROVEN = { patient_ptinfo: [ :ssn ] }.freeze

  # Patient.brief_header flags only (A/D in ORWPT CWAD) — not C/W slots (#224 round-3).
  # A flag is proven only when some live-captured CWAD row yields true via brief_header;
  # false is just a missing letter and never counts as evidence.
  BRIEF_HEADER_READINESS_FLAGS = %i[allergy_flag ad_flag].freeze

  # Medication.active_for_patient keys (api/medication.rb) — not :active_text alone.
  MEDICATION_ACTIVE_READINESS_KEYS = %i[
    order_id type name status stop_date instructions comments
  ].freeze

  # Mapped booleans (e.g. :inactive_icd on :problem_list) need a mapped true row and a mapped
  # false row whose raw wire carries the field piece empty (truncated rows must not prove false).
  BOOLEAN_MAPPED_ATTRIBUTES = { problem_list: [ :inactive_icd ] }.freeze

  # Single-piece RPC error / sentinel replies — not record rows; must not prove any field.
  NON_RECORD_LIVE_CAPTURE_ROWS = [
    "Application context denied",
    "%YDB-E-LVUNDEF, Undefined local variable: DFN",
    "0"
  ].freeze

  # Round-5 (#512): caret-bearing VistA failure / YDB / sentinel rows — not record evidence.
  YDB_ZSTATUS_LIVE_CAPTURE_ROW =
    "150373850,LIST+3^ORQQPL,%YDB-E-LVUNDEF, Undefined local variable: DFN".freeze

  # Round-6 (#512): M stack text after piece 0 (unanchored code,LABEL+off^ROUTINE / %YDB-E).
  M_LOCATION_STACK_LINE_LIVE_CAPTURE_ROWS = [
    "1^150373850,LIST+3^ORQQPL, Undefined local variable: DFN",
    "2^x^150373850,GET+1^ORWPT,%YDB-E-LVUNDEF"
  ].freeze

  # Omit "1^2^Application context denied": round-5 panel contrived it; live broker
  # failures are the single-piece reply in NON_RECORD_LIVE_CAPTURE_ROWS or a
  # \x01-framed "-N^…" line, and `rake wire:capture` drops both via non_data_row? /
  # captured_data_rows — so rules 1–4 never need to reject that caret shape.
  CARET_CONTAINING_NON_RECORD_LIVE_CAPTURE_ROWS = [
    "0^Patient not found",
    "-1^Invalid DFN",
    "0^No problems^^^^^^^^^^^",
    YDB_ZSTATUS_LIVE_CAPTURE_ROW,
    "^No vitals found.^^oops",
    *M_LOCATION_STACK_LINE_LIVE_CAPTURE_ROWS
  ].freeze

  # Fake client: ORWPS ACTIVE lines exactly as CiaClient#call_rpc delivers them (no seq prefix).
  class MedicationActiveProbeClient
    def initialize(lines) = @lines = lines

    def call_rpc(rpc, *)
      raise "unexpected RPC #{rpc}" unless rpc == "ORWPS ACTIVE"

      @lines
    end
  end

  # Fake client for Patient.brief_header CWAD probe — post-CiaClient scalar shape.
  class BriefHeaderCwadProbeClient
    PTINFO = "USER,TEST^M^2850115^XXX-XX-1234^^^^^^^^^^^MRN123^^^^^^^^^PROV,ONE^TEAM^PROV,ONE"

    def initialize(cwad) = @cwad = cwad.to_s

    def call_rpc(rpc, *)
      case rpc
      when "BEHOPTCX PTINFO" then PTINFO
      when "BEHOPTPC GETBDP" then ""
      when "ORWPT CWAD" then @cwad
      else raise "unexpected RPC #{rpc}"
      end
    end
  end

  # Slice RPCs for patient chart reads (#218). :inputs are what the gem's public
  # API sends today (lib/rpms_rpc/api/* + DataMapper fetch params).
  CHART_READ_SLICE = [
    { rpc: "ORWPT ID INFO", mapping: :patient_id_info, kind: "fields",
      inputs: [ "2" ], evidence: :live },
    { rpc: "BEHOPTCX PTINFO", mapping: :patient_ptinfo, kind: "fields",
      inputs: [ "2" ], evidence: :live },
    { rpc: "BEHOPTPC GETBDP", mapping: :patient_designated_provider, kind: "fields",
      inputs: [ "2" ], evidence: :no_data },
    { rpc: "ORWPT CWAD", mapping: :patient_cwad, kind: "scalar",
      inputs: nil, evidence: :routine_cite },
    { rpc: "ORQQPL LIST", mapping: :problem_list, kind: "fields",
      inputs: [ "2", "" ], evidence: :live },
    { rpc: "ORQQAL LIST", mapping: :allergy_list, kind: "fields",
      inputs: [ "2" ], evidence: :live },
    { rpc: "ORWPS ACTIVE", mapping: :medication_active, kind: "text_blob",
      inputs: [ "2" ], evidence: :no_data },
    { rpc: "ORQQVI VITALS", mapping: :vitals, kind: "fields",
      inputs: [ "2" ], evidence: :live }
  ].freeze

  CHART_FIELDS_READINESS_MAPPINGS = CHART_READ_SLICE.filter_map do |slice|
    next if %i[patient_cwad medication_active].include?(slice[:mapping])
    next unless slice[:kind] == "fields"

    slice[:mapping]
  end.freeze

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
      slug = rpc.downcase.tr(" /", "--")
      RpmsRpc::WireCapture::CATALOG.find { |entry| entry.fixture_name == slug && entry.rpc == rpc }
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

    def normalize_cite(text)
      text.to_s.gsub(/\s+/, " ").strip
    end

    def fixture_signed_on_as(fixture)
      return nil unless fixture.path

      YAML.safe_load_file(fixture.path)["signed_on_as"]
    end

    def forced_unproven?(mapping_name, attribute, fixture)
      return true if BEHOPTCX_FORCED_UNPROVEN.fetch(mapping_name, []).include?(attribute)

      # $$HRN / MRN depends on sign-on division — pilot captures as PROV123 (blank MRN).
      if mapping_name == :patient_ptinfo && attribute == :mrn
        persona = fixture_signed_on_as(fixture)
        return true if persona && persona != CHART_READ_PERSONA
      end

      false
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
        mapping.parse_many(evidence_rows(mapping, fixture))
      end
    end

    def fields_kind_chart_read_evidence?(mapping, fixture)
      return false if mapping.scalar? || mapping.text_blob?
      return false if %i[patient_cwad medication_active].include?(fixture.mapping_name)

      true
    end

    # Piece text that is itself an integer. String#to_i would turn a word into 0.
    def real_integer_token?(piece)
      token = piece.to_s.strip
      token.match?(/\A-?\d+\z/) && RpmsRpc::WireCapture::Evidence.real_value?(token)
    end

    # M error text: %YDB-E, $ZSTATUS, or code,LABEL+off^ROUTINE anywhere in the row. Not a record.
    def m_error_text?(text)
      text.include?("%YDB-E") || text.include?("$ZSTATUS") ||
        text.match?(/\d+,[A-Z0-9%]+\+\d+\^/)
    end

    # Record evidence needs a real key, no M error text, and two real pieces.
    # Empty piece 0 is the ORWPT ID INFO shape only when piece 1 is an integer token (^2850505^...); a sentinel message is not.
    def record_row?(row)
      text = row.to_s
      return false if m_error_text?(text)

      pieces = text.split("^", -1)
      head = pieces[0].to_s.strip
      return false if real_integer_token?(head) && head.to_i <= 0
      return false if head.empty? && !real_integer_token?(pieces[1])

      pieces.count { |piece| RpmsRpc::WireCapture::Evidence.real_value?(piece.to_s.strip) } >= 2
    end

    def evidence_rows(mapping, fixture)
      rows = fixture.captured_data_rows
      return rows unless fields_kind_chart_read_evidence?(mapping, fixture)

      rows.select { |row| record_row?(row) }
    end

    def mapped_value_present?(value)
      RpmsRpc::WireCapture::Evidence.real_value?(value)
    end

    # String#to_i turns a non-numeric placeholder into 0, and Evidence treats
    # 0 as real. An integer attribute counts only when a wire piece is itself
    # a real integer token.
    def attribute_populated_in_mapped_capture?(mapping, fixture, attribute)
      return false if coerced_integer_lacks_real_token?(mapping, fixture, attribute)

      mapped_rows_for_fixture(mapping, fixture).any? do |row|
        mapped_value_present?(row[attribute])
      end
    end

    def coerced_integer_lacks_real_token?(mapping, fixture, attribute)
      return false if mapping.scalar? || mapping.text_blob?

      field = mapping.fields.find { |candidate| candidate.attribute == attribute && candidate.type == :integer }
      return false unless field

      evidence_rows(mapping, fixture).none? do |row|
        token = row.to_s.split("^", -1)[field.position].to_s.strip
        token.match?(/\A-?\d+\z/) && RpmsRpc::WireCapture::Evidence.real_value?(token)
      end
    end

    def boolean_values_observed_in_mapped_capture?(mapping, fixture, attribute)
      field = mapping.fields.find { |candidate| candidate.attribute == attribute }
      return false unless field

      true_observed = false
      false_observed = false

      evidence_rows(mapping, fixture).each do |raw_row|
        mapped = mapping.parse_many([ raw_row ]).first
        next if mapped.nil?

        case mapped[attribute]
        when true
          true_observed = true
        when false
          pieces = raw_row.to_s.split("^", -1)
          next unless pieces.length > field.position

          false_observed = true if pieces[field.position].to_s.strip.empty?
        end
      end

      true_observed && false_observed
    end

    def medication_active_value_present?(value)
      RpmsRpc::WireCapture::Evidence.real_value?(value)
    end

    def medication_active_rows_via_api(fixture)
      return [] if fixture.captured_data_rows.empty?

      client = MedicationActiveProbeClient.new(fixture.captured_data_rows)
      RpmsRpc.reset!
      RpmsRpc.configure { |cfg| cfg.client = client }
      RpmsRpc::Medication.active_for_patient("2")
    ensure
      RpmsRpc.reset!
    end

    def medication_active_attribute_proven?(fixture, attribute)
      medication_active_rows_via_api(fixture).any? do |row|
        medication_active_value_present?(row[attribute])
      end
    end

    def brief_header_from_cwad_scalar(cwad_scalar)
      client = BriefHeaderCwadProbeClient.new(cwad_scalar)
      RpmsRpc.reset!
      RpmsRpc.configure { |cfg| cfg.client = client }
      RpmsRpc::Patient.brief_header(2)
    ensure
      RpmsRpc.reset!
    end

    def brief_header_flag_observed_true?(fixture, flag)
      fixture.captured_data_rows.any? do |row|
        header = brief_header_from_cwad_scalar(row)
        header && header[flag] == true
      rescue RpmsRpc::Client::RpcError
        false
      end
    end

    def piece4_icd_code_shaped?(piece4)
      token = piece4.to_s.strip
      return false if token.empty?

      token.match?(RpmsRpc::Mappings::PROBLEM_LIST_ICD_CODE_SHAPE)
    end

    def readiness_attribute_names(mapping, fixture)
      case fixture.mapping_name
      when :patient_cwad then BRIEF_HEADER_READINESS_FLAGS
      when :medication_active then MEDICATION_ACTIVE_READINESS_KEYS
      else mapped_attribute_names(mapping)
      end
    end

    def unproven_attributes(fixture)
      mapping = RpmsRpc::DataMapper[fixture.mapping_name]
      names = readiness_attribute_names(mapping, fixture)
      return names if fixture.source == "no-data" || fixture.source == "routine-cite" ||
                      fixture.captured_data_rows.empty?

      boolean_attrs = BOOLEAN_MAPPED_ATTRIBUTES.fetch(fixture.mapping_name, [])

      names.select do |attribute|
        if fixture.mapping_name == :patient_cwad
          !brief_header_flag_observed_true?(fixture, attribute)
        elsif fixture.mapping_name == :medication_active
          !medication_active_attribute_proven?(fixture, attribute)
        elsif boolean_attrs.include?(attribute)
          !boolean_values_observed_in_mapped_capture?(mapping, fixture, attribute)
        else
          forced_unproven?(fixture.mapping_name, attribute, fixture) ||
            !attribute_populated_in_mapped_capture?(mapping, fixture, attribute)
        end
      end
    end

    def format_unproven_list(attributes)
      attributes.empty? ? "none" : attributes.map(&:to_s).sort.join(", ")
    end

    def expected_checklist_status(slice, fixture)
      unproven = unproven_attributes(fixture)
      mapping = RpmsRpc::DataMapper[fixture.mapping_name]
      all_readiness = readiness_attribute_names(mapping, fixture)
      if slice[:rpc] == "ORQQPL LIST" && orqqpl_inactive_icd_mapping_leaks?
        "fails-live"
      elsif fixture.source == "no-data" || fixture.source == "routine-cite"
        "not-proven"
      elsif unproven.empty?
        "pilot-ready"
      elsif unproven.sort == all_readiness.sort
        "not-proven"
      else
        "partial"
      end
    end

    # Round-3 SPEC: inactive_icd follows piece 13 "#" alone (ORQQPL.m:15-16).
    # Replaces round-2 pin that also required piece 9 "#".
    def orqqpl_inactive_icd_mapping_leaks?
      path = fixture_path_for("ORQQPL LIST")
      return false unless File.file?(path)

      mapper = RpmsRpc::DataMapper[:problem_list]
      fixture = RpmsRpc::WireCapture::Fixture.load_file(path)
      fixture.captured_data_rows.any? do |row|
        pieces = row.split("^", -1)
        parsed = mapper.parse_many([ row ]).first
        next false if parsed.nil?

        marker = pieces[12] == "#"
        inactive = parsed[:inactive_icd] == true
        next true if marker != inactive
        next true if inactive && mapped_value_present?(parsed[:icd_code])
        next true if !marker && mapped_value_present?(parsed[:icd_code]) &&
                      !piece4_icd_code_shaped?(pieces[3])

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

  # Intent: checklist reason lines name the chart-read persona (PROV123).
  def test_pilot_checklist_reasons_name_chart_read_persona
    rows = parse_checklist
    failures = []
    CHART_READ_SLICE.each do |slice|
      row = rows[slice[:rpc]]
      next failures << "#{slice[:rpc]}: missing checklist row" unless row

      unless row[:reason].match?(/PROV123/)
        failures << "#{slice[:rpc]} line #{row[:line]}: reason must name persona PROV123"
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
      case slice[:evidence]
      when :live, :no_data
        failures << "#{slice[:rpc]}: catalog mode #{entry.mode.inspect}, expected :live" unless entry.live?
      when :routine_cite
        unless entry.mode == :routine_cite
          failures << "#{slice[:rpc]}: catalog mode #{entry.mode.inspect}, expected :routine_cite"
        end
      end
      failures << "#{slice[:rpc]}: maps :#{entry.mapping}, expected :#{slice[:mapping]}" if entry.mapping != slice[:mapping]
      failures << "#{slice[:rpc]}: kind #{entry.kind.inspect}, expected #{slice[:kind].inspect}" if entry.kind != slice[:kind]
      expected_inputs = slice[:evidence] == :routine_cite ? nil : slice[:inputs]
      if entry.inputs != expected_inputs
        failures << "#{slice[:rpc]}: inputs #{entry.inputs.inspect}, expected #{expected_inputs.inspect}"
      end
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

  # Intent: MRN ($$HRN) depends on sign-on division — blank under PROV123, populated under SYS123.
  def test_behoptcx_ptinfo_mrn_unproven_derived_from_capture_and_persona
    slice = CHART_READ_SLICE.find { |s| s[:mapping] == :patient_ptinfo }
    fixture = load_slice_fixture(slice)
    mapping = RpmsRpc::DataMapper[:patient_ptinfo]
    persona = self.class.fixture_signed_on_as(fixture)
    if persona == "SYS123"
      mapped = mapping.parse_one(fixture.captured_data_rows.first)
      assert self.class.mapped_value_present?(mapped[:mrn]),
             "SYS123 capture should populate MRN on the wire (division-specific)"
    end
    expected = self.class.forced_unproven?(:patient_ptinfo, :mrn, fixture) ||
               !self.class.attribute_populated_in_mapped_capture?(mapping, fixture, :mrn)
    unproven = self.class.unproven_attributes(fixture)
    assert_equal expected, unproven.include?(:mrn),
                 expected ? "MRN must be unproven for this fixture/persona" : "MRN must not be unproven when piece 11 is populated"

    base_row = fixture.captured_data_rows.first
    refute_nil base_row, "BEHOPTCX PTINFO fixture must carry a row for MRN stub cases"

    populated_row = ptinfo_row_with_mrn_piece(base_row, "MRN999")
    populated_stub = Struct.new(:mapping_name, :source, :captured_data_rows, :path).new(
      :patient_ptinfo, "live-capture", [ populated_row ], nil
    )
    refute_includes self.class.unproven_attributes(populated_stub), :mrn,
                    "piece 11 MRN token must prove :mrn when persona does not force unproven"

    blank_row = ptinfo_row_with_mrn_piece(base_row, "")
    blank_stub = Struct.new(:mapping_name, :source, :captured_data_rows, :path).new(
      :patient_ptinfo, "live-capture", [ blank_row ], nil
    )
    assert_includes self.class.unproven_attributes(blank_stub), :mrn,
                    "blank piece 11 must leave :mrn unproven"

    dir = Dir.mktmpdir("pilot_ptinfo_persona")
    begin
      sys_path = File.join(dir, "sys123.yml")
      File.write(sys_path, YAML.dump({ "signed_on_as" => "SYS123" }))
      sys_stub = Struct.new(:mapping_name, :source, :captured_data_rows, :path).new(
        :patient_ptinfo, "live-capture", [ populated_row ], sys_path
      )
      assert_includes self.class.unproven_attributes(sys_stub), :mrn,
                      "SYS123 persona must force :mrn unproven even when piece 11 is populated"

      prov_path = File.join(dir, "prov123.yml")
      File.write(prov_path, YAML.dump({ "signed_on_as" => CHART_READ_PERSONA }))
      prov_stub = Struct.new(:mapping_name, :source, :captured_data_rows, :path).new(
        :patient_ptinfo, "live-capture", [ populated_row ], prov_path
      )
      refute_includes self.class.unproven_attributes(prov_stub), :mrn,
                      "PROV123 persona must not force :mrn unproven when piece 11 is populated"
    ensure
      FileUtils.remove_entry(dir)
    end
  end

  def ptinfo_row_with_mrn_piece(base_row, mrn_token)
    pieces = base_row.split("^", -1)
    pieces.fill("", pieces.length...11) if pieces.length < 11
    pieces[10] = mrn_token
    pieces.join("^")
  end

  # Intent: each slice fixture cite matches its CatalogEntry (stale fixtures fail after catalog edits).
  def test_chart_read_fixture_cite_matches_catalog_entry
    failures = []
    CHART_READ_SLICE.each do |slice|
      entry = self.class.catalog_entry_for(slice[:rpc])
      path = self.class.fixture_path_for(slice[:rpc])
      next failures << "#{slice[:rpc]}: no fixture" unless File.file?(path)

      data = YAML.safe_load_file(path)
      fixture_cite = self.class.normalize_cite(data["cite"])
      catalog_cite = self.class.normalize_cite(entry.cite)
      next if fixture_cite == catalog_cite

      failures << "#{slice[:rpc]}: fixture cite differs from lib/rpms_rpc/wire_capture.rb catalog"
    end
    assert_empty failures, failures.join("\n  ")
  end

  # Intent: signed_on_as PROV123 on every chart-read live/no-data fixture (#224 round-3).
  # Replaces round-2 rule that expected SYS123 from default wire:capture sign-on.
  def test_chart_read_live_and_no_data_fixtures_record_chart_read_persona
    failures = []
    CHART_READ_SLICE.each do |slice|
      path = self.class.fixture_path_for(slice[:rpc])
      next failures << "#{slice[:rpc]}: no fixture" unless File.file?(path)

      data = YAML.safe_load_file(path)
      source = data["source"]
      next unless %w[live-capture no-data].include?(source)

      actual = data["signed_on_as"]
      if actual != CHART_READ_PERSONA
        failures << "#{slice[:rpc]} (#{source}): signed_on_as #{actual.inspect}, " \
                     "expected #{CHART_READ_PERSONA.inspect} (clinician pilot persona)"
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
      next unless slice[:evidence] == :no_data

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
    CHART_READ_SLICE.select { |s| s[:evidence] == :no_data }.each do |slice|
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

  # ORQQPL LIST inactive-ICD (#224 round-3): piece 13 "#" alone. Replaces round-2 pin on pieces 13 and 9.
  def test_orqqpl_list_inactive_icd_rows_map_nil_codes_and_flag_inactive_icd
    mapper = RpmsRpc::DataMapper[:problem_list]

    inactive_real_code =
      "3^Diabetes^A^250.00^3230410^3261012^^^#^^^ORQQPL DETAIL^#"
    parsed = mapper.parse_many([ inactive_real_code ]).first
    refute_nil parsed
    assert_equal true, parsed[:inactive_icd],
                 "piece 13 '#' marker must set inactive_icd even when piece 4 is a real inactive code"
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

    non_code_piece4 = [
      "Invalid Code (not found in the ICD-9-CM system)",
      "Code not found",
      "NO SUCH ENTRY",
      "-1",
      "UNKNOWN CODE (not on file)",
      ""
    ]
    non_code_piece4.each do |piece4|
      row = "99^Hypertension^A^#{piece4}^3200101^3250301^^^^^"
      parsed_row = mapper.parse_many([ row ]).first
      refute parsed_row[:inactive_icd], "piece 4 #{piece4.inspect} without '#' must not set inactive_icd"
      assert_nil parsed_row[:icd_code],
                 "non-code-shaped piece 4 #{piece4.inspect} must map to nil icd_code"
    end

    code_shaped_piece4 = %w[
      I10 E11.65 Z79.4 250.00 V45.81 E849.0 401.9
      S72.001A M54.50 T38.0X5A U07.1
    ]
    code_shaped_piece4.each do |code|
      row = "99^Hypertension^A^#{code}^3200101^3250301^^^^^"
      parsed_row = mapper.parse_many([ row ]).first
      assert_equal code.strip, parsed_row[:icd_code],
                   "code-shaped piece 4 must map to stripped icd_code"
      refute parsed_row[:inactive_icd]
    end

    icd_code_near_misses = %w[000 E849.00 E11. i10]
    icd_code_near_misses.each do |code|
      row = "99^Hypertension^A^#{code}^3200101^3250301^^^^^"
      parsed_row = mapper.parse_many([ row ]).first
      refute parsed_row[:inactive_icd]
      assert_nil parsed_row[:icd_code],
                 "near-miss piece 4 #{code.inspect} must not become icd_code"
    end

    padded_row = "99^Hypertension^A^ I10 ^3200101^3250301^^^^^"
    padded = mapper.parse_many([ padded_row ]).first
    assert_equal "I10", padded[:icd_code],
                 "surrounding whitespace on code-shaped piece 4 must strip to icd_code"
  end

  def test_problem_list_inactive_icd_boolean_readiness_requires_wire_piece_for_false
    inactive_row =
      "3^Diabetes^A^Invalid Code (not found in the ICD-9-CM system)^3230410^3261012^^^#^^^^#"
    truncated_row = "2^HTN"
    twelve_piece_row = "2^HTN^A^I10^3200101^3250301^^^^^^"
    active_thirteen_piece_row =
      "123^Hypertension^A^I10^3200101^3250301^NSC^SPEXP^Y^HIGH^^^"

    stub_truncated = Struct.new(:mapping_name, :source, :captured_data_rows, :path).new(
      :problem_list, "live-capture", [ inactive_row, truncated_row ], nil
    )
    assert_includes self.class.unproven_attributes(stub_truncated), :inactive_icd,
                    "truncated row must not prove inactive_icd false"

    stub_twelve = Struct.new(:mapping_name, :source, :captured_data_rows, :path).new(
      :problem_list, "live-capture", [ inactive_row, twelve_piece_row ], nil
    )
    assert_includes self.class.unproven_attributes(stub_twelve), :inactive_icd,
                    "row missing piece 13 must not prove inactive_icd false"

    stub_proven = Struct.new(:mapping_name, :source, :captured_data_rows, :path).new(
      :problem_list, "live-capture", [ inactive_row, active_thirteen_piece_row ], nil
    )
    refute_includes self.class.unproven_attributes(stub_proven), :inactive_icd,
                    "inactive true plus active row with empty piece 13 proves both boolean values"

    stub_only_active = Struct.new(:mapping_name, :source, :captured_data_rows, :path).new(
      :problem_list, "live-capture", [ active_thirteen_piece_row ], nil
    )
    assert_includes self.class.unproven_attributes(stub_only_active), :inactive_icd,
                    "active-only rows must not prove inactive_icd without a true observation"

    thirteen_piece_placeholders = [
      "^" * 12,
      "0#{"^" * 12}",
      "**MASKED**#{"^" * 12}",
      "Application context denied#{"^" * 12}"
    ]
    thirteen_piece_placeholders.each do |placeholder|
      stub = Struct.new(:mapping_name, :source, :captured_data_rows, :path).new(
        :problem_list, "live-capture", [ inactive_row, placeholder ], nil
      )
      assert_includes self.class.unproven_attributes(stub), :inactive_icd,
                      "13-piece placeholder #{placeholder.inspect} must not prove inactive_icd false"
    end
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

  def test_orwpt_cwad_routine_cite_fixture_is_honest_not_proven
    slice = CHART_READ_SLICE.find { |s| s[:mapping] == :patient_cwad }
    path = self.class.fixture_path_for(slice[:rpc])
    assert File.file?(path), "missing #{path} — routine-cite ORWPT CWAD fixture required"

    fixture = RpmsRpc::WireCapture::Fixture.load_file(path)
    assert_equal "routine-cite", fixture.source
    assert_equal :patient_cwad, fixture.mapping_name
    assert_empty fixture.captured_data_rows, "routine-cite CWAD must not claim captured data rows"

    unproven = self.class.unproven_attributes(fixture)
    assert_equal self.class::BRIEF_HEADER_READINESS_FLAGS.sort, unproven.sort
    assert_equal "not-proven", self.class.expected_checklist_status(slice, fixture)

    rows = parse_checklist
    row = rows[slice[:rpc]]
    refute_nil row, "checklist must list ORWPT CWAD"
    assert_equal "not-proven", row[:status]
    assert_equal "ad_flag, allergy_flag", row[:unproven]
  end

  def test_patient_cwad_live_capture_readiness_via_brief_header_flags
    slice = CHART_READ_SLICE.find { |s| s[:mapping] == :patient_cwad }
    cwad_slice = slice

    {
      [ "A" ] => { unproven: [ :ad_flag ], status: "partial" },
      [ "D" ] => { unproven: [ :allergy_flag ], status: "partial" },
      [ "AD" ] => { unproven: [], status: "pilot-ready" },
      [ "CW" ] => { unproven: [ :ad_flag, :allergy_flag ], status: "not-proven" },
      [ "-1^Invalid DFN" ] => { unproven: [ :ad_flag, :allergy_flag ], status: "not-proven" },
      [ "Application context denied" ] => { unproven: [ :ad_flag, :allergy_flag ], status: "not-proven" },
      [ "%YDB-E-LVUNDEF, Undefined local variable: DFN" ] =>
        { unproven: [ :ad_flag, :allergy_flag ], status: "not-proven" }
    }.each do |rows, expected|
      stub = Struct.new(:mapping_name, :source, :captured_data_rows, :path).new(
        :patient_cwad, "live-capture", rows, nil
      )
      unproven = self.class.unproven_attributes(stub)
      assert_equal expected[:unproven].sort, unproven.sort, "CWAD #{rows.inspect} unproven"
      refute_includes unproven, :crisis_flag
      refute_includes unproven, :warning_flag
      assert_equal expected[:status], self.class.expected_checklist_status(cwad_slice, stub),
                   "CWAD #{rows.inspect} checklist status"
    end
  end

  # ORWPS ACTIVE readiness uses Medication.active_for_patient, not :active_text mapping alone.
  def test_orwps_active_readiness_non_empty_unparseable_blob_proves_nothing
    slice = CHART_READ_SLICE.find { |s| s[:mapping] == :medication_active }
    stub = Struct.new(:mapping_name, :source, :captured_data_rows, :path).new(
      :medication_active, "live-capture", [ "garbage without tilde headers" ], nil
    )
    unproven = self.class.unproven_attributes(stub)
    assert_equal self.class::MEDICATION_ACTIVE_READINESS_KEYS.sort, unproven.sort,
                 "unparseable text must not prove medication fields"
    assert_equal "not-proven", self.class.expected_checklist_status(slice, stub),
                 "live capture that proves zero medication fields grades not-proven"
  end

  # Live-capture error text that maps to no vitals fields — every readiness key unproven, not partial.
  def test_orqqvi_vitals_live_capture_error_grades_not_proven
    slice = CHART_READ_SLICE.find { |s| s[:rpc] == "ORQQVI VITALS" }
    stub = Struct.new(:mapping_name, :source, :captured_data_rows, :path).new(
      :vitals, "live-capture", [ "Application context denied" ], nil
    )
    mapping = RpmsRpc::DataMapper[:vitals]
    expected_names = self.class.readiness_attribute_names(mapping, stub)
    unproven = self.class.unproven_attributes(stub)
    assert_equal expected_names.sort, unproven.sort,
                 "error reply must leave every vitals readiness field unproven"
    assert_equal "not-proven", self.class.expected_checklist_status(slice, stub)
  end

  # Single-piece sentinel / error rows are not record rows — no fields-kind mapping may grade partial.
  def test_fields_kind_live_capture_non_record_rows_grade_not_proven
    failures = []
    NON_RECORD_LIVE_CAPTURE_ROWS.each do |error_row|
      CHART_FIELDS_READINESS_MAPPINGS.each do |mapping_name|
        slice = CHART_READ_SLICE.find { |s| s[:mapping] == mapping_name }
        stub = Struct.new(:mapping_name, :source, :captured_data_rows, :path).new(
          mapping_name, "live-capture", [ error_row ], nil
        )
        mapping = RpmsRpc::DataMapper[mapping_name]
        all_readiness = self.class.readiness_attribute_names(mapping, stub).sort
        unproven = self.class.unproven_attributes(stub).sort
        if unproven != all_readiness
          failures << ":#{mapping_name} row #{error_row.inspect}: unproven #{unproven.inspect}, expected all #{all_readiness.inspect}"
        end
        status = self.class.expected_checklist_status(slice, stub)
        next if status == "not-proven"

        failures << ":#{mapping_name} row #{error_row.inspect}: status #{status.inspect}, expected not-proven"
      end
    end
    assert_empty failures, failures.join("\n  ")
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
