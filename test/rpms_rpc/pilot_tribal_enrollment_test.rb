# frozen_string_literal: true

require "minitest/autorun"
require "digest"
require "fileutils"
require "yaml"
require "rpms_rpc"
require "rpms_rpc/live_summary"
require "rpms_rpc/wire_capture"
require "rpms_rpc/mappings"
require "rpms_rpc/api/tribal"
require "rpms_rpc/api/registration"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/mock_client"

# Issue #566 (tribal enrollment slice): pilot-ready wire evidence on the pinned build.
#
# SPEC only — fails until the implementer adds CatalogEntry fixture: names,
# re-captures fixtures as PROV123 on synthetic seed (DFN 2 tribal reads), and
# extends docs/pilot_rpc_readiness.md. See pilot_chart_reads_test.rb (#512).
class RpmsRpc::PilotTribalEnrollmentTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  LOCK_PATH = File.join(ROOT, "data/fingerprints/rpms-ops.lock.yml")
  CHECKLIST_PATH = File.join(ROOT, "docs/pilot_rpc_readiness.md")
  LIVE_ELIGIBILITY_SPEC = File.join(ROOT, "test/live/registration_eligibility_update_live_test.rb")

  PINNED_RELEASE = RpmsRpc::LiveSummary.pinned_build(LOCK_PATH).freeze
  PILOT_PERSONA = "PROV123"

  Ddr = RpmsRpc::DdrFileman
  Tribal = RpmsRpc::Tribal
  Registration = RpmsRpc::Registration

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

  CHART_READ_CHECKLIST_RPCS = [
    "ORWPT ID INFO", "BEHOPTCX PTINFO", "BEHOPTPC GETBDP", "ORWPT CWAD",
    "ORQQPL LIST", "ORQQAL LIST", "ORWPS ACTIVE", "ORQQVI VITALS"
  ].freeze

  # API method -> fixture_name -> underlying DDR RPC (issue #566 synthetic seed, DFN 2).
  TRIBAL_SLICE = [
    { checklist_key: "Tribal.enrollment", fixture_name: "tribal-enrollment",
      rpc: "DDR GETS ENTRY DATA", mapping: :ddr_gets_entry_data, kind: "text_blob",
      api: -> { Tribal.enrollment(2) } },
    { checklist_key: "Tribal.eligibility", fixture_name: "tribal-eligibility",
      rpc: "DDR GETS ENTRY DATA", mapping: :ddr_gets_entry_data, kind: "text_blob",
      api: -> { Tribal.eligibility(2) } },
    { checklist_key: "Tribal.tribe_info", fixture_name: "tribal-tribe-info",
      rpc: "DDR GETS ENTRY DATA", mapping: :ddr_gets_entry_data, kind: "text_blob",
      api: -> { Tribal.tribe_info(1) } },
    { checklist_key: "Tribal.service_unit", fixture_name: "tribal-service-unit",
      rpc: "DDR GETS ENTRY DATA", mapping: :ddr_gets_entry_data, kind: "text_blob",
      api: -> { Tribal.service_unit(1) } },
    { checklist_key: "Tribal.tribes", fixture_name: "tribal-tribes",
      rpc: "DDR LISTER", mapping: :ddr_lister, kind: "text_blob",
      api: -> { Tribal.tribes(part: "A") } },
    { checklist_key: "Tribal.communities", fixture_name: "tribal-communities",
      rpc: "DDR LISTER", mapping: :ddr_lister, kind: "text_blob",
      api: -> { Tribal.communities(part: "AT") } },
    { checklist_key: "Tribal.validate", fixture_name: "tribal-validate-valid",
      rpc: "DDR VALIDATOR", mapping: :ddr_validator, kind: "text_blob",
      api: -> { Tribal.validate("12345") } },
    { checklist_key: "Tribal.validate", fixture_name: "tribal-validate-invalid",
      rpc: "DDR VALIDATOR", mapping: :ddr_validator, kind: "text_blob",
      api: -> { Tribal.validate("X" * 40) } }
  ].freeze

  TRIBAL_CHECKLIST_KEYS = TRIBAL_SLICE.map { |s| s[:checklist_key] }.uniq.freeze

  ENROLLMENT_READINESS_KEYS = %i[
    enrollment_number tribe_ien tribe_name tribe_quantum indian_blood_quantum
    classification_ien classification eligibility_status community
  ].freeze

  ELIGIBILITY_READINESS_KEYS = %i[
    eligibility_status eligibility_status_name classification_ien classification
  ].freeze

  TRIBE_INFO_READINESS_KEYS = %i[ien name code].freeze
  SERVICE_UNIT_READINESS_KEYS = %i[ien name].freeze
  TRIBES_READINESS_KEYS = %i[ien name].freeze
  COMMUNITIES_READINESS_KEYS = %i[ien name county state].freeze
  VALIDATE_READINESS_KEYS = %i[valid internal external].freeze

  WINDOW_ELIGIBILITY_ATTRS = Registration::UPDATE_ATTRIBUTES.select do |_, attr|
    attr.window == Registration::WINDOW_ELIGIBILITY
  end.keys.freeze

  class CiaFramedReplayClient
    def initialize(raw_return)
      @raw = raw_return
    end

    def call_rpc(_rpc_name, *_params)
      body = parse_cia_reply(@raw)
      lines = body.split(/\r\n|\r|\n|\x1e/).reject { |line| line == "\x1f" }
      RpmsRpc::Reply.from_wire(lines, controls: true)
    end

    private

    def parse_cia_reply(raw)
      bytes = raw.to_s.b
      rest = bytes.byteslice(1..) || "".b
      case rest.getbyte(0)
      when 0x00 then rest.byteslice(1..) || "".b
      when 0x01 then raise RpmsRpc::Client::RpcError, rest.byteslice(1..).to_s
      else "".b
      end
    end
  end

  class << self
    def catalog_slug(entry)
      return entry.fixture_name if entry.respond_to?(:fixture_name)

      entry.rpc.downcase.tr(" /", "--")
    end

    def catalog_entry_for_fixture(fixture_name)
      RpmsRpc::WireCapture::CATALOG.find { |entry| catalog_slug(entry) == fixture_name }
    end

    def entry_fixture_name(entry)
      fail "CatalogEntry must implement #fixture_name (optional fixture: keyword in catalog)" unless entry.respond_to?(:fixture_name)

      entry.fixture_name
    end

    def fixture_path_for(entry)
      fail "WireCapture.fixture_path(entry) must return FIXTURES_DIR/<fixture_name>.yml" unless RpmsRpc::WireCapture.respond_to?(:fixture_path)

      RpmsRpc::WireCapture.fixture_path(entry)
    end

    def readiness_keys_for(checklist_key)
      case checklist_key
      when "Tribal.enrollment" then ENROLLMENT_READINESS_KEYS
      when "Tribal.eligibility" then ELIGIBILITY_READINESS_KEYS
      when "Tribal.tribe_info" then TRIBE_INFO_READINESS_KEYS
      when "Tribal.service_unit" then SERVICE_UNIT_READINESS_KEYS
      when "Tribal.tribes" then TRIBES_READINESS_KEYS
      when "Tribal.communities" then COMMUNITIES_READINESS_KEYS
      when "Tribal.validate" then VALIDATE_READINESS_KEYS
      else
        raise ArgumentError, checklist_key
      end
    end

    def list_checklist_key?(checklist_key)
      %w[Tribal.tribes Tribal.communities].include?(checklist_key)
    end

    def replay_results_for_slices(slices)
      slices.map do |slice|
        entry = catalog_entry_for_fixture(slice[:fixture_name])
        fail "#{slice[:fixture_name]}: no catalog entry" unless entry

        path = fixture_path_for(entry)
        fail "#{slice[:fixture_name]}: missing fixture at #{path}" unless File.file?(path)

        fixture = RpmsRpc::WireCapture::Fixture.load_file(path)
        client = CiaFramedReplayClient.new(fixture.raw_return)
        RpmsRpc.reset!
        RpmsRpc.configure { |cfg| cfg.client = client }
        result = slice[:api].call
        fail "#{slice[:fixture_name]} replay returned nil" if result.nil?

        result
      ensure
        RpmsRpc.reset!
      end
    end

    def proven_readiness_keys(checklist_key, replay_results)
      keys = readiness_keys_for(checklist_key)
      if checklist_key == "Tribal.validate"
        valid_true = replay_results.any? { |row| row[:valid] == true }
        valid_false = replay_results.any? { |row| row[:valid] == false }
        keys.select do |attribute|
          case attribute
          when :valid then valid_true && valid_false
          else replay_results.any? { |row| RpmsRpc::WireCapture::Evidence.real_value?(row[attribute]) }
          end
        end
      elsif list_checklist_key?(checklist_key)
        rows = replay_results.flatten(1)
        keys.select { |attribute| rows.any? { |row| RpmsRpc::WireCapture::Evidence.real_value?(row[attribute]) } }
      else
        row = replay_results.first
        keys.select { |attribute| RpmsRpc::WireCapture::Evidence.real_value?(row[attribute]) }
      end
    end

    def unproven_readiness_keys(checklist_key, slices)
      results = replay_results_for_slices(slices)
      proven = proven_readiness_keys(checklist_key, results)
      readiness_keys_for(checklist_key) - proven
    end

    def format_unproven_list(attributes)
      attributes.empty? ? "none" : attributes.map(&:to_s).sort.join(", ")
    end

    def expected_checklist_status(checklist_key, unproven)
      all = readiness_keys_for(checklist_key)
      if unproven.empty?
        "pilot-ready"
      elsif unproven.sort == all.sort
        "not-proven"
      else
        "partial"
      end
    end

    def recorded_catalog_inputs(slice)
      mock = RpmsRpc.mock!
      seed_minimal_ddr_reply(slice, mock)
      slice[:api].call
      call = mock.received_calls.find { |c| c[:rpc] == slice[:rpc] }
      fail "#{slice[:fixture_name]}: expected one #{slice[:rpc]} call" unless call

      call[:params]
    ensure
      RpmsRpc.reset!
    end

    def seed_minimal_ddr_reply(slice, mock)
      case slice[:rpc]
      when "DDR GETS ENTRY DATA"
        param = recorded_gets_param(slice)
        mock.seed(:ddr_gets_entry_data, param.to_s, "[Data]\n9000001^2^.07^^")
      when "DDR LISTER"
        param = recorded_lister_param(slice)
        mock.seed(:ddr_lister, param.to_s, "[Data]\n1^OTHER")
      when "DDR VALIDATOR"
        param = recorded_validator_param(slice)
        internal = slice[:fixture_name].end_with?("-invalid") ? "^" : "12345"
        mock.seed(:ddr_validator, param.to_s, "[FILLER]\n[Data]\n#{internal}\n#{internal}")
      else
        fail "unknown rpc #{slice[:rpc]}"
      end
    end

    def recorded_gets_param(slice)
      case slice[:fixture_name]
      when "tribal-enrollment"
        Ddr.gets_entry_param(file: Registration::PATIENT_FILE, iens: "2,",
                             fields: Tribal::ENROLLMENT_FIELDS, flags: "IE")
      when "tribal-eligibility"
        Ddr.gets_entry_param(file: Registration::PATIENT_FILE, iens: "2,",
                             fields: Tribal::ELIGIBILITY_FIELDS, flags: "IE")
      when "tribal-tribe-info"
        Ddr.gets_entry_param(file: Tribal::TRIBE_FILE, iens: "1,", fields: ".01;.02", flags: "IE")
      when "tribal-service-unit"
        Ddr.gets_entry_param(file: Tribal::SERVICE_UNIT_FILE, iens: "1,", fields: ".01", flags: "IE")
      else
        fail "no gets param recipe for #{slice[:fixture_name]}"
      end
    end

    def recorded_lister_param(slice)
      case slice[:fixture_name]
      when "tribal-tribes"
        Ddr.lister_param(file: Tribal::TRIBE_FILE, fields: Tribal::NAME_ONLY, part: "A", xref: "B")
      when "tribal-communities"
        Ddr.lister_param(file: Tribal::COMMUNITY_FILE, fields: Tribal::COMMUNITY_FIELDS, part: "AT", xref: "B")
      else
        fail "no lister param recipe for #{slice[:fixture_name]}"
      end
    end

    def recorded_validator_param(slice)
      value = slice[:fixture_name].end_with?("-invalid") ? ("X" * 40) : "12345"
      Ddr.validator_param(file: Registration::PATIENT_FILE, iens: "", field: Tribal::FIELD_ENROLLMENT_NUMBER,
                          value: value)
    end

    def slices_for_checklist_key(key)
      TRIBAL_SLICE.select { |s| s[:checklist_key] == key }
    end
  end

  def parse_checklist
    assert File.file?(CHECKLIST_PATH),
           "missing docs/pilot_rpc_readiness.md — tribal pilot status must be written for humans and CI"

    rows = {}
    File.readlines(CHECKLIST_PATH, chomp: true).each_with_index do |line, idx|
      next if line.strip.empty? || line.lstrip.start_with?("#")

      m = CHECKLIST_LINE.match(line)
      unless m
        flunk "line #{idx + 1}: expected 'KEY | status | reason | unproven: …', got #{line.inspect}"
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
    entry = self.class.catalog_entry_for_fixture(slice[:fixture_name])
    assert entry, "#{slice[:fixture_name]}: no catalog entry"
    path = self.class.fixture_path_for(entry)
    assert File.file?(path), "#{slice[:fixture_name]}: no fixture at #{path}"

    RpmsRpc::WireCapture::Fixture.load_file(path)
  end

  def test_pinned_release_is_the_issue_566_build
    assert_equal "bcer-9.0-20261012-e7923a4-ydb", PINNED_RELEASE
  end

  def test_wire_capture_fixture_path_uses_fixture_name_basename
    entry = self.class.catalog_entry_for_fixture("tribal-enrollment")
    assert entry, "catalog must include tribal-enrollment (fixture: keyword, mode :live)"
    path = self.class.fixture_path_for(entry)
    assert_equal File.join(RpmsRpc::WireCapture::FIXTURES_DIR, "tribal-enrollment.yml"), path
    refute_equal File.join(RpmsRpc::WireCapture::FIXTURES_DIR, "ddr-gets-entry-data.yml"), path,
                 "tribal GETS captures must not overwrite the generic ddr-gets-entry-data.yml"
  end

  def test_catalog_fixture_names_are_unique
    names = RpmsRpc::WireCapture::CATALOG.map { |entry| self.class.entry_fixture_name(entry) }
    duplicates = names.group_by(&:itself).select { |_, group| group.size > 1 }.keys
    assert_empty duplicates,
                 "every CatalogEntry fixture_name must be unique (duplicate: #{duplicates.join(", ")})"
  end

  def test_existing_ddr_gets_entry_data_catalog_entry_keeps_rpc_slug_fixture_name
    entry = RpmsRpc::WireCapture::CATALOG.find { |e| e.rpc == "DDR GETS ENTRY DATA" && e.inputs&.dig(0, "IENS") == "8," }
    refute_nil entry, "committed phone-fields DDR GETS ENTRY DATA entry must remain in the catalog"
    assert_respond_to entry, :fixture_name, "CatalogEntry#fixture_name must exist after the fixture: catalog change"
    assert_equal "ddr-gets-entry-data", entry.fixture_name
  end

  def test_catalog_has_live_tribal_slice_entries_with_api_recorded_inputs
    failures = []
    TRIBAL_SLICE.each do |slice|
      entry = self.class.catalog_entry_for_fixture(slice[:fixture_name])
      if entry.nil?
        failures << "#{slice[:fixture_name]}: no CatalogEntry (fixture: #{slice[:fixture_name].inspect}, mode :live)"
        next
      end
      failures << "#{slice[:fixture_name]}: mode #{entry.mode.inspect}, expected :live" unless entry.live?
      failures << "#{slice[:fixture_name]}: maps :#{entry.mapping}, expected :#{slice[:mapping]}" if entry.mapping != slice[:mapping]
      failures << "#{slice[:fixture_name]}: kind #{entry.kind.inspect}, expected #{slice[:kind].inspect}" if entry.kind != slice[:kind]
      expected_inputs = self.class.recorded_catalog_inputs(slice)
      if entry.inputs != expected_inputs
        failures << "#{slice[:fixture_name]}: inputs #{entry.inputs.inspect}, expected #{expected_inputs.inspect} from API"
      end
    end
    assert_empty failures, "tribal enrollment catalog gaps:\n  #{failures.join("\n  ")}"
  end

  def test_each_tribal_slice_fixture_exists_at_fixture_path
    missing = TRIBAL_SLICE.filter_map do |slice|
      entry = self.class.catalog_entry_for_fixture(slice[:fixture_name])
      next slice[:fixture_name] unless entry

      path = self.class.fixture_path_for(entry)
      File.basename(path) unless File.file?(path)
    end
    assert_empty missing,
                 "missing fixture(s) — run rake wire:capture as #{PILOT_PERSONA}: #{missing.join(", ")}"
  end

  def test_tribal_live_capture_fixtures_are_stamped_on_the_pinned_build
    failures = []
    TRIBAL_SLICE.each do |slice|
      fixture = load_slice_fixture(slice)
      entry = self.class.catalog_entry_for_fixture(slice[:fixture_name])
      expected_inputs = entry.inputs
      failures << "#{slice[:fixture_name]}: source #{fixture.source.inspect}, expected live-capture" unless fixture.source == "live-capture"
      failures << "#{slice[:fixture_name]}: release_tag #{fixture.release_tag.inspect}, expected #{PINNED_RELEASE}" if fixture.release_tag != PINNED_RELEASE
      failures << "#{slice[:fixture_name]}: inputs #{fixture.inputs.inspect}, expected #{expected_inputs.inspect}" if fixture.inputs != expected_inputs
      failures << "#{slice[:fixture_name]}: signed_on_as #{fixture_signed_on_as(slice).inspect}, expected #{PILOT_PERSONA.inspect}" if fixture_signed_on_as(slice) != PILOT_PERSONA
      actual_sha = Digest::SHA256.hexdigest(fixture.raw_return)
      failures << "#{slice[:fixture_name]}: sha256 mismatch" if fixture.sha256 != actual_sha
      failures << "#{slice[:fixture_name]}: raw is a broker error reply" if RpmsRpc::WireCapture.error_reply?(fixture.raw_return)
    end
    assert_empty failures, failures.join("\n  ")
  end

  def fixture_signed_on_as(slice)
    entry = self.class.catalog_entry_for_fixture(slice[:fixture_name])
    path = self.class.fixture_path_for(entry)
    return nil unless File.file?(path)

    YAML.safe_load_file(path)["signed_on_as"]
  end

  def test_tribal_live_capture_fixture_headers_warn_against_hand_editing
    failures = []
    TRIBAL_SLICE.each do |slice|
      entry = self.class.catalog_entry_for_fixture(slice[:fixture_name])
      path = self.class.fixture_path_for(entry)
      next failures << "#{slice[:fixture_name]}: no fixture" unless File.file?(path)

      fixture = RpmsRpc::WireCapture::Fixture.load_file(path)
      failures << "#{slice[:fixture_name]}: source #{fixture.source.inspect}, expected live-capture" unless fixture.source == "live-capture"

      comments = File.readlines(path, chomp: true).take(5).select { |l| l.start_with?("#") }.join("\n")
      unless comments.match?(/do not hand-edit/i)
        failures << "#{slice[:fixture_name]}: header must warn not to hand-edit (#{path})"
      end
      unless comments.match?(/VERBATIM|re-run the capture/i)
        failures << "#{slice[:fixture_name]}: header must cite verbatim capture provenance (#{path})"
      end
    end
    assert_empty failures, failures.join("\n  ")
  end

  def test_tribal_checklist_covers_every_slice_api_method
    rows = parse_checklist
    missing = TRIBAL_CHECKLIST_KEYS - rows.keys
    assert_empty missing,
                 "docs/pilot_rpc_readiness.md must list every tribal slice method (#{missing.join(", ")})"
  end

  def test_tribal_checklist_field_level_readiness_matches_replayed_fixtures
    rows = parse_checklist
    failures = []
    TRIBAL_CHECKLIST_KEYS.each do |key|
      row = rows[key]
      failures << "#{key}: missing checklist row" unless row

      slices = self.class.slices_for_checklist_key(key)
      unproven = self.class.unproven_readiness_keys(key, slices)
      expected_unproven = self.class.format_unproven_list(unproven)
      if row && row[:unproven] != expected_unproven
        failures << "#{key} line #{row[:line]}: unproven #{row[:unproven].inspect}, " \
                     "expected #{expected_unproven.inspect} from replay + Evidence"
      end

      expected_status = self.class.expected_checklist_status(key, unproven)
      if row && row[:status] != expected_status
        failures << "#{key} line #{row[:line]}: status #{row[:status].inspect}, expected #{expected_status.inspect}"
      end
    end
    assert_empty failures, failures.join("\n  ")
  end

  def test_tribal_enrollment_checklist_documents_seed_data_gap_for_blank_enrollment_number
    rows = parse_checklist
    row = rows["Tribal.enrollment"]
    refute_nil row, "checklist must include Tribal.enrollment"
    assert_equal "partial", row[:status]
    assert_includes row[:unproven], "enrollment_number"
    assert_match(/seed.?data gap/i, row[:reason])
    assert_match(/\.07|enrollment/i, row[:reason])
    assert_match(/PROV123/, row[:reason])
  end

  def test_registration_update_eligibility_checklist_row
    rows = parse_checklist
    row = rows["Registration.update eligibility"]
    refute_nil row, "checklist must include Registration.update eligibility write row"
    assert_includes row[:reason], "test/live/registration_eligibility_update_live_test.rb"
    assert_match(/BENEFICIARY|9999999\.25/i, row[:reason])
    assert_match(/OTHER|seed.?data gap/i, row[:reason])

    if live_eligibility_spec_covers_window_eligibility_attrs?
      assert_equal "pilot-ready", row[:status]
      assert_equal "none", row[:unproven]
    end
  end

  def test_checklist_header_lists_registration_eligibility_live_spec_as_fails_live
    header = File.readlines(CHECKLIST_PATH, chomp: true).take_while { |l| l.start_with?("#") }.join("\n")
    assert_match(/registration_eligibility_update_live_test\.rb/i, header)
    assert_match(/fails-live|failed live/i, header,
                 "header must list mappings/specs that failed live although hermetic tests passed")
  end

  def test_chart_read_checklist_rows_still_parse
    rows = parse_checklist
    missing = CHART_READ_CHECKLIST_RPCS - rows.keys
    assert_empty missing, "tribal checklist edits must not break chart-read rows (#{missing.join(", ")})"
  end

  def test_live_eligibility_spec_does_not_hard_code_beneficiary_classification_name
    source = File.read(LIVE_ELIGIBILITY_SPEC)
    refute_match(/INDIAN\/ALASKA NATIVE/, source,
                 "live spec must pick a classification from #9999999.25 on the build, not a missing name")
  end

  def test_live_eligibility_spec_covers_ag_eligibility_window_update_and_readback
    assert live_eligibility_spec_covers_window_eligibility_attrs?,
           "#{LIVE_ELIGIBILITY_SPEC} must write every WINDOW_ELIGIBILITY UPDATE_ATTRIBUTES key and read each back"
  end

  private

  def live_eligibility_spec_covers_window_eligibility_attrs?
    source = File.read(LIVE_ELIGIBILITY_SPEC)
    update_ok = WINDOW_ELIGIBILITY_ATTRS.all? do |attr|
      source.match?(/(?<![a-z_])#{Regexp.escape(attr.to_s)}:\s/)
    end
    read_ok = source.include?('"1108"') && source.include?('"1111"') && source.include?('"1112"') &&
              source.include?('"1110"') && source.include?('"1109"') && source.include?('".07"') &&
              source.match?(/Tribal\.enrollment/) &&
              source.match?(/\.values_at\(:enrollment_number/)
    update_ok && read_ok && source.match?(/Registration\.update/) && source.match?(/990[_ ]?052/)
  end
end
