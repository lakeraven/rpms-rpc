# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "yaml"
require "rpms_rpc"
require "rpms_rpc/live_summary"
require "rpms_rpc/wire_capture"
require "rpms_rpc/mappings"
require "rpms_rpc/api/agg"

# Issue #562 (registration slice of #224): pilot wire evidence for AGG
# registration RPCs on the pinned build as PROV123.
class RpmsRpc::PilotRegistrationTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  LOCK_PATH = File.join(ROOT, "data/fingerprints/rpms-ops.lock.yml")
  CHECKLIST_PATH = File.join(ROOT, "docs/pilot_rpc_readiness.md")
  DRIVER_PATH = File.join(ROOT, "bin/wire_capture_driver.rb")

  PINNED_RELEASE = RpmsRpc::LiveSummary.pinned_build(LOCK_PATH).freeze
  PERSONA = "PROV123"

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

  LOOKUP_CANDIDATE_PARAMS = {
    "AGGPTLNM" => "USER",
    "AGGPTFNM" => "TEST",
    "AGGPTDOB" => "05/05/1985"
  }.freeze

  REGISTRATION_CHECKLIST_RPCS = [
    "AGG LOOKUP PATIENTS",
    "AGG ADD NEW PATIENT",
    "AGG UPDATE PATIENT",
    "AGG GET TEMP PAT HRN"
  ].freeze

  WRITE_CHECKLIST_RPCS = [
    "AGG ADD NEW PATIENT",
    "AGG UPDATE PATIENT",
    "AGG GET TEMP PAT HRN"
  ].freeze

  LOOKUP_MAPPING_ATTRIBUTES = RpmsRpc::DataMapper[:patient_lookup_agg].fields.map(&:attribute).freeze

  class RecordingClient
    attr_reader :contexts, :calls

    def initialize
      @contexts = []
      @calls = []
      @current_context = nil
    end

    def with_context(name)
      @contexts << name
      previous = @current_context
      @current_context = name
      yield
    ensure
      @current_context = previous
    end

    def call_rpc_global_array(rpc, *params)
      @calls << { rpc: rpc, params: params, context: @current_context }
      header = "I00010DFN^T00030PATIENT_NAME^T00030HRN^T00009SSN^D00030DOB^D00030DOD^T00003SENS_FLAG^T01024ALIAS^T00001INACTIVE"
      "5\x00#{header}\x1e\x1f"
    end

    def call_rpc(*) = raise "unexpected scalar RPC"
  end

  class << self
    def fixture_path_for(rpc)
      File.join(RpmsRpc::WireCapture::FIXTURES_DIR, "#{rpc.downcase.tr(" /", "--")}.yml")
    end

    def catalog_entry_for(rpc)
      RpmsRpc::WireCapture::CATALOG.find { |e| e.rpc == rpc }
    end

    def lookup_catalog_entry
      catalog_entry_for("AGG LOOKUP PATIENTS")
    end

    def unproven_lookup_attributes(fixture)
      mapping = RpmsRpc::DataMapper[:patient_lookup_agg]
      names = LOOKUP_MAPPING_ATTRIBUTES
      return names if fixture.captured_data_rows.empty?

      mapped = fixture.captured_data_rows.filter_map do |row|
        mapping.parse_many([ row ]).first
      end
      return names if mapped.empty?

      names.select do |attribute|
        mapped.none? { |row| RpmsRpc::WireCapture::Evidence.real_value?(row[attribute]) }
      end
    end

    def format_unproven_list(attributes)
      attributes.empty? ? "none" : attributes.map(&:to_s).sort.join(", ")
    end

    def expected_lookup_checklist_status(fixture)
      unproven = unproven_lookup_attributes(fixture)
      if fixture.source == "no-data" || fixture.captured_data_rows.empty?
        "not-proven"
      elsif unproven.empty?
        "pilot-ready"
      elsif unproven.sort == LOOKUP_MAPPING_ATTRIBUTES.sort
        "not-proven"
      else
        "partial"
      end
    end

    def wire_contract_violations(fixture)
      mapping = RpmsRpc::DataMapper[fixture.mapping_name]
      RpmsRpc::WireCapture::Contract.check(mapping, fixture)
    end
  end

  def parse_checklist
    assert File.file?(CHECKLIST_PATH),
           "missing docs/pilot_rpc_readiness.md — registration pilot status must be written"

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

  def test_catalog_entry_has_context_and_agg_lookup_patients_live_inputs
    entry = self.class.lookup_catalog_entry
    refute_nil entry, "lib/rpms_rpc/wire_capture.rb must catalog AGG LOOKUP PATIENTS"

    assert_respond_to entry, :context, "CatalogEntry must expose context for AGGRPC captures"
    assert entry.live?, "AGG LOOKUP PATIENTS must be a :live catalog entry"
    assert_equal :patient_lookup_agg, entry.mapping
    assert_equal "fields", entry.kind
    assert_equal "AGGRPC", entry.context
    refute_empty entry.inputs, "catalog must declare live capture inputs"
  end

  def test_catalog_agg_lookup_inputs_match_registration_candidates_call
    entry = self.class.lookup_catalog_entry
    skip "catalog entry missing" unless entry

    client = RecordingClient.new
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = client }
    RpmsRpc::Agg.registration_candidates(LOOKUP_CANDIDATE_PARAMS)

    call = client.calls.find { |c| c[:rpc] == "AGG LOOKUP PATIENTS" }
    refute_nil call, "registration_candidates must call AGG LOOKUP PATIENTS"
    assert_equal entry.inputs, call[:params],
                 "catalog inputs must match Agg.registration_candidates wire params"
  ensure
    RpmsRpc.reset!
  end

  def test_catalog_agg_lookup_cite_and_pieces_cover_patient_lookup_agg
    entry = self.class.lookup_catalog_entry
    skip "catalog entry missing" unless entry

    cite = entry.cite.to_s
    assert_match(/FND\^AGGPTLKP/, cite)
    assert_match(/HDR\^AGGPTLKP/, cite)

    positions = entry.pieces.map(&:position).sort
    assert_equal (0..10).to_a, positions
    assert_equal LOOKUP_MAPPING_ATTRIBUTES.sort,
                 entry.pieces.flat_map(&:attributes).map(&:to_sym).sort.uniq
  end

  def test_wire_capture_driver_binds_entry_context_before_calling
    src = File.read(DRIVER_PATH, mode: "rb").force_encoding(Encoding::UTF_8)
    loop_body = src[/entries\.each do \|entry\|[\s\S]*?^end/m]
    refute_nil loop_body, "could not locate capture loop in bin/wire_capture_driver.rb"
    assert_match(/entry\.context/, loop_body, "driver must read catalog entry context")
    assert_match(/with_context/, loop_body, "driver must bind context before call_rpc_raw")
  end

  def test_committed_agg_lookup_patients_fixture_exists_and_passes_contract
    path = self.class.fixture_path_for("AGG LOOKUP PATIENTS")
    assert File.file?(path), "missing #{path} — run rake wire:capture for AGG LOOKUP PATIENTS as PROV123"

    fixture = RpmsRpc::WireCapture::Fixture.load_file(path)
    entry = self.class.lookup_catalog_entry
    skip "catalog entry missing" unless entry

    assert_equal "live-capture", fixture.source
    assert_equal PINNED_RELEASE, fixture.release_tag
    assert_equal PERSONA, YAML.safe_load_file(path)["signed_on_as"]
    assert_equal entry.inputs, fixture.inputs
    assert_empty self.class.wire_contract_violations(fixture),
                 "AGG LOOKUP PATIENTS fixture must pass :patient_lookup_agg wire contract"
  end

  def test_pilot_checklist_lists_registration_rpcs
    rows = parse_checklist
    missing = REGISTRATION_CHECKLIST_RPCS - rows.keys
    assert_empty missing,
                 "docs/pilot_rpc_readiness.md must list registration RPCs (#{missing.join(", ")})"
  end

  def test_pilot_checklist_agg_lookup_readiness_derived_from_fixture
    rows = parse_checklist
    path = self.class.fixture_path_for("AGG LOOKUP PATIENTS")
    skip "fixture missing" unless File.file?(path)

    fixture = RpmsRpc::WireCapture::Fixture.load_file(path)
    row = rows["AGG LOOKUP PATIENTS"]
    refute_nil row, "checklist must include AGG LOOKUP PATIENTS"

    expected_unproven = self.class.format_unproven_list(self.class.unproven_lookup_attributes(fixture))
    assert_equal expected_unproven, row[:unproven],
                 "AGG LOOKUP PATIENTS unproven list must match the committed capture"

    expected_status = self.class.expected_lookup_checklist_status(fixture)
    assert_equal expected_status, row[:status]
    assert_match(/PROV123/, row[:reason])
  end

  def test_pilot_checklist_write_rpcs_are_not_proven_and_name_hrn_readback
    rows = parse_checklist
    WRITE_CHECKLIST_RPCS.each do |rpc|
      row = rows[rpc]
      refute_nil row, "checklist must include #{rpc}"
      assert_equal "not-proven", row[:status], "#{rpc} writes cannot be pilot-ready from capture alone"
      refute_includes %w[pilot-ready partial], row[:status]
      assert_match(/PROV123/, row[:reason])
      assert_match(/9000001\.41/, row[:reason], "#{rpc} reason must cite #9000001.41 HRN read-back")
    end
  end
end
