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
  LIVE_RUN_RECORD_PATH = File.join(ROOT, "test/fixtures/live_runs/registration-eligibility-update.yml")
  LIVE_RUN_RECORD_REL = "test/fixtures/live_runs/registration-eligibility-update.yml"
  WIRE_CAPTURE_DRIVER_PATH = File.join(ROOT, "bin/wire_capture_driver.rb")
  WIRE_RAKE_PATH = File.join(ROOT, "lib/tasks/wire.rake")

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

  CHART_READ_WIRE_FIXTURE_RPCS = CHART_READ_CHECKLIST_RPCS

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
      api: -> { Tribal.tribes(part: "OTHER") } },
    { checklist_key: "Tribal.communities", fixture_name: "tribal-communities",
      rpc: "DDR LISTER", mapping: :ddr_lister, kind: "text_blob",
      api: -> { Tribal.communities(part: "STONEHAM") } },
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

  # :ien on tribe_info/service_unit is the caller's IEN argument echoed (Tribal.rb), not wire proof.
  TRIBE_INFO_READINESS_KEYS = %i[name code].freeze
  SERVICE_UNIT_READINESS_KEYS = %i[name].freeze
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

    def validate_proof_from_raw?(row, raw_return, want_valid:)
      raw = raw_return.to_s
      return false unless raw.include?("[Data]")
      if want_valid
        return false if raw.include?("[BEGIN_diERRORS]")
      else
        return false unless raw.include?("[BEGIN_diERRORS]")
        return false unless raw.include?("^")
      end
      return false unless row[:valid] == want_valid

      true
    end

    def validator_attribute_proven?(attribute, row)
      value = row[attribute]
      return false if value.nil? || value == "" || value == "^"

      RpmsRpc::WireCapture::Evidence.real_value?(value)
    end

    def list_attribute_proven?(attribute, row)
      if attribute == :ien
        ien = row[attribute]
        return false unless ien.is_a?(Integer) && ien.positive?
      end
      RpmsRpc::WireCapture::Evidence.real_value?(row[attribute])
    end

    # Pointer fields on enrollment/eligibility: internal_ien must fail closed (nil unless
    # positive Integer). Evidence.real_value?(0) is true, so do not use it for IEN columns.
    def pointer_ien_proven?(value)
      value.is_a?(Integer) && value.positive?
    end

    def enrollment_eligibility_attribute_proven?(attribute, row)
      case attribute
      when :tribe_ien, :classification_ien then pointer_ien_proven?(row[attribute])
      else RpmsRpc::WireCapture::Evidence.real_value?(row[attribute])
      end
    end

    def proven_readiness_keys(checklist_key, replay_results, validate_raws: nil)
      keys = readiness_keys_for(checklist_key)
      if checklist_key == "Tribal.validate"
        raws = Array(validate_raws)
        valid_true = replay_results.each_with_index.any? do |row, idx|
          validate_proof_from_raw?(row, raws[idx], want_valid: true)
        end
        valid_false = replay_results.each_with_index.any? do |row, idx|
          validate_proof_from_raw?(row, raws[idx], want_valid: false)
        end
        keys.select do |attribute|
          case attribute
          when :valid then valid_true && valid_false
          when :internal, :external
            replay_results.any? { |row| validator_attribute_proven?(attribute, row) }
          else
            replay_results.any? { |row| RpmsRpc::WireCapture::Evidence.real_value?(row[attribute]) }
          end
        end
      elsif list_checklist_key?(checklist_key)
        rows = replay_results.flatten(1)
        keys.select { |attribute| rows.any? { |row| list_attribute_proven?(attribute, row) } }
      else
        row = replay_results.first
        keys.select { |attribute| enrollment_eligibility_attribute_proven?(attribute, row) }
      end
    end

    def rpc_slug_for(entry)
      entry.rpc.downcase.tr(" /", "--")
    end

    def live_eligibility_spec_non_comment_source(source)
      source.lines.reject { |line| line.strip.start_with?("#") }.join
    end

    def live_eligibility_spec_filed_attr_assignments_ok?(source)
      code = live_eligibility_spec_non_comment_source(source)
      code.match?(/^\s*eligibility_status\s*=.*before\[:eligibility_status\]/m) &&
        code.match?(/^\s*blood_quantum\s*=.*before\[:indian_blood_quantum\]/m) &&
        code.match?(/^\s*tribe_quantum\s*=.*before\[:tribe_quantum\]/m) &&
        code.match?(/^\s*tribe\s*=.*tribe_row\[:ien\]/m)
    end

    def live_eligibility_spec_refute_pre_test_values_ok?(source)
      code = live_eligibility_spec_non_comment_source(source)
      code.match?(/before_internal\s*=\s*\{/) &&
        code.match?(/expected\.each\s+do\s+\|field,\s*value\|/) &&
        code.match?(/refute_equal\s+before_internal\[field\]/)
    end

    WINDOW_ELIGIBILITY_FILED_FIELD_VARS = {
      '".07"' => "number",
      '"1108"' => "tribe",
      '"1109"' => "tribe_quantum",
      '"1110"' => "blood_quantum",
      '"1111"' => "classification",
      '"1112"' => "eligibility_status"
    }.freeze

    def live_eligibility_spec_assert_equal_expected_filed_ok?(source)
      code = live_eligibility_spec_non_comment_source(source)
      return false unless code.match?(/^\s*assert_equal\s+expected,\s+filed\s*$/m)

      body = code[/expected\s*=\s*\{([^}]+)\}/m, 1]
      return false unless body

      WINDOW_ELIGIBILITY_FILED_FIELD_VARS.all? do |field_key, var_name|
        body.match?(/#{Regexp.escape(field_key)}\s*=>\s*#{var_name}\b/)
      end
    end

    def live_eligibility_spec_filed_from_gets_entry_ok?(source)
      code = live_eligibility_spec_non_comment_source(source)
      code.match?(/DdrFileman\.gets_entry/m) &&
        code.match?(/fields:\s*"[^"]*\.07[^"]*1108[^"]*1109[^"]*1110[^"]*1111[^"]*1112/m) &&
        code.match?(/%w\[\.07\s+1108\s+1109\s+1110\s+1111\s+1112\]/) &&
        code.match?(/filed\s*=.*\.dig\(:fields,\s*f,\s*:internal\)/m)
    end

    STANDING_READBACK_ASSERT_EQUAL = /
      assert_equal\s*\[\s*number\s*,\s*tribe_quantum\s*,\s*blood_quantum\s*,\s*eligibility_status\s*\]\s*,
      \s*standing\.values_at\(\s*:enrollment_number\s*,\s*:tribe_quantum\s*,\s*:indian_blood_quantum\s*,\s*:eligibility_status\s*\)
    /mx

    def live_eligibility_spec_standing_readback_assert_equal_ok?(source)
      code = live_eligibility_spec_non_comment_source(source)
      return false unless code.match?(STANDING_READBACK_ASSERT_EQUAL)

      standing_assign = code[/standing\s*=\s*RpmsRpc::Tribal\.enrollment\s*\(\s*DFN\s*\)/m]
      !standing_assign.nil? && code.index(standing_assign) < code.index("assert_equal [ number")
    end

    def live_eligibility_spec_tribe_selection_ok?(source)
      code = live_eligibility_spec_non_comment_source(source)
      update_uses_bare_tribe_id = code.match?(/Registration\.update\([\s\S]*?\btribe:\s*[a-z_][a-z0-9_]*\b/m)
      update_uses_tribe_literal = code.match?(/Registration\.update\([\s\S]*?\btribe:\s*["']|Registration\.update\([\s\S]*?\btribe:\s*\d/m)
      from_tribes_row = code.match?(/Tribal\.tribes\b/) &&
                        code.match?(/tribe_row\s*=/) &&
                        code.match?(/tribe\s*=.*tribe_row\[:ien\]/m)

      update_uses_bare_tribe_id && !update_uses_tribe_literal && from_tribes_row
    end

    def live_eligibility_spec_part_string_literals_ok?(source)
      code = live_eligibility_spec_non_comment_source(source)
      code.scan(/part:\s*(["'])(.*?)\1/).all? { |(_, value)| value == "OTHER" }
    end

    def tribal_tribes_fixture_catch_all_other?(path = File.join(RpmsRpc::WireCapture::FIXTURES_DIR, "tribal-tribes.yml"))
      return false unless File.file?(path)

      data = YAML.safe_load_file(path)
      part = data.dig("inputs", 0, "PART") || data.dig("inputs", 0, :PART)
      return false unless part.to_s == "OTHER"

      raw = data["raw_return"]
      lister_data_rows(raw).all? do |row|
        pieces = row.split("^")
        name = pieces[1].to_s
        name.empty? || name == "OTHER"
      end
    end

    def live_eligibility_spec_covers_window_eligibility_attrs?(source = nil)
      source = source || File.read(LIVE_ELIGIBILITY_SPEC, encoding: Encoding::UTF_8)
      lines = source.lines
      return false if source.match?(/^\s*skip\b/m) || source.match?(/\bskip\s+"|\bskip\s+'/)

      def_line = lines.find { |l| l =~ /^\s*def test_/ }
      return false unless def_line && !def_line.strip.start_with?("#")

      update_line = lines.find { |l| l.include?("Registration.update") && !l.strip.start_with?("#") }
      return false unless update_line

      return false unless source.match?(/Tribal\.enrollment\s*\(\s*DFN\s*\)/)

      update_ok = WINDOW_ELIGIBILITY_ATTRS.all? do |attr|
        source.match?(/(?<![a-z_])#{Regexp.escape(attr.to_s)}:\s/)
      end
      wire_readback_ok = live_eligibility_spec_standing_readback_assert_equal_ok?(source) &&
                         source.match?(/\b990[_ ]?052\b/)
      assert_filed_ok = live_eligibility_spec_assert_equal_expected_filed_ok?(source)
      gets_entry_filed_ok = live_eligibility_spec_filed_from_gets_entry_ok?(source)
      tribes_ok = live_eligibility_spec_tribe_selection_ok?(source)
      part_literals_ok = live_eligibility_spec_part_string_literals_ok?(source)
      fixture_other_ok = tribal_tribes_fixture_catch_all_other?
      filed_ok = live_eligibility_spec_filed_attr_assignments_ok?(source)
      refute_ok = live_eligibility_spec_refute_pre_test_values_ok?(source)
      update_ok && wire_readback_ok && assert_filed_ok && gets_entry_filed_ok && tribes_ok &&
        part_literals_ok && fixture_other_ok && filed_ok && refute_ok && source.match?(/Registration\.update/)
    end

    def live_eligibility_spec_no_op_mutant(source)
      mutant = source.dup
      mutant.sub!(/^\s*eligibility_status = .*$/, '    eligibility_status = "C"')
      mutant.sub!(/^\s*blood_quantum = .*$/, '    blood_quantum = "1/2"')
      mutant.sub!(/^\s*tribe_quantum = .*$/, '    tribe_quantum = "1/4"')
      mutant.sub!(/^\s*before_internal = \{.*?\n    \}\n/m, "")
      mutant.sub!(/^\s*expected\.each do \|field, value\|\n.*?^\s*end\n/m, "")
      mutant
    end

    def live_eligibility_spec_mutant_delete_assert_equal(source)
      source.lines.reject { |line| line.match?(/^\s*assert_equal\s+expected,\s+filed\s*$/) }.join
    end

    def live_eligibility_spec_mutant_remove_expected_field(source, field_key, var_name)
      mutant = source.dup
      mutant.sub!(/#{Regexp.escape(field_key)}\s*=>\s*#{var_name}\s*,?\s*/, "")
      mutant
    end

    def live_eligibility_spec_mutant_delete_standing_readback_assert_equal(source)
      source.lines.reject do |line|
        line.match?(/^\s*assert_equal\s+\[\s*number\s*,\s*tribe_quantum\s*,\s*blood_quantum\s*,\s*eligibility_status\s*\]/)
      end.join
    end

    def live_eligibility_spec_mutant_comment_standing_readback_assert_equal(source)
      source.gsub(
        /^(\s*)assert_equal\s+\[\s*number\s*,\s*tribe_quantum\s*,\s*blood_quantum\s*,\s*eligibility_status\s*\]/,
        '\1# assert_equal [ number, tribe_quantum, blood_quantum, eligibility_status ]'
      )
    end

    def live_eligibility_spec_mutant_refute_nil_standing_readback(source)
      source.sub(
        /^\s*assert_equal\s+\[\s*number\s*,\s*tribe_quantum\s*,\s*blood_quantum\s*,\s*eligibility_status\s*\].*$/,
        "    refute_nil standing"
      )
    end

    def live_eligibility_spec_mutant_registration_update_tribe_string_literal(source)
      source.sub(/(\btribe:\s*)tribe\b/, '\1"12"')
    end

    def live_eligibility_spec_mutant_tribes_part_not_other(source)
      source.sub(/Array\(RpmsRpc::Tribal\.tribes\)/, 'Array(RpmsRpc::Tribal.tribes(part: "ZZTRIBE"))')
    end

    def load_live_run_record
      return nil unless File.file?(LIVE_RUN_RECORD_PATH)

      YAML.safe_load_file(LIVE_RUN_RECORD_PATH)
    end

    def synthetic_live_run_record(overrides = {})
      {
        "spec" => LIVE_ELIGIBILITY_SPEC.sub("#{ROOT}/", ""),
        "persona" => PILOT_PERSONA,
        "protocol" => "cia",
        "build" => PINNED_RELEASE,
        "build_source" => "pinned",
        "build_marker" => "synthetic-marker",
        "run_id" => "a1b2c3d4e5f6789012345678901234ab",
        "run_at" => "2026-11-05T12:00:00Z",
        "passed" => true,
        "runs" => 1,
        "assertions" => 10,
        "failures" => 0,
        "errors" => 0,
        "skips" => 0
      }.merge(overrides)
    end

    def synthetic_pilot_ready_eligibility_row(record)
      date = record["run_at"].to_s[0, 10]
      {
        status: "pilot-ready",
        unproven: "none",
        reason: "live spec #{LIVE_ELIGIBILITY_SPEC.sub("#{ROOT}/", "")} persona #{record["persona"]} " \
                "build #{record["build"]} run #{record["run_id"]} on #{date} " \
                "record #{LIVE_RUN_RECORD_REL} AG Eligibility window"
      }
    end

    def live_run_record_consistency_errors(row, record, pinned_build: PINNED_RELEASE)
      errors = []
      status = row[:status].to_s
      reason = row[:reason].to_s
      unproven = row[:unproven].to_s
      cites_record = reason.include?(LIVE_RUN_RECORD_REL)

      case status
      when "pilot-ready"
        if record.nil?
          errors << "pilot-ready requires live run record at #{LIVE_RUN_RECORD_REL}"
          return errors
        end

        %w[spec persona protocol build build_source build_marker run_id run_at passed runs assertions failures errors skips].each do |key|
          errors << "record missing key #{key}" unless record.key?(key)
        end

        errors << "record passed must be true" unless record["passed"] == true
        errors << "record passed must be boolean" if record["passed"].is_a?(String)
        errors << "record failures must be 0" unless record["failures"].to_i.zero?
        errors << "record errors must be 0" unless record["errors"].to_i.zero?
        errors << "record runs must be >= 1" unless record["runs"].to_i >= 1
        spec_path = "test/live/registration_eligibility_update_live_test.rb"
        errors << "record spec must be live eligibility spec" unless record["spec"] == spec_path
        errors << "record build must match pinned build" unless record["build"] == pinned_build
        errors << "record build_source must be pinned" unless record["build_source"] == "pinned"
        errors << "row unproven must be none" unless unproven == "none"
        errors << "row reason must cite live run record path" unless cites_record
        errors << "row reason must cite persona" unless reason.include?(record["persona"].to_s)
        run_id = record["run_id"].to_s
        errors << "record run_id must be present" if run_id.empty?
        errors << "row reason must cite run_id" if !run_id.empty? && !reason.include?(run_id)
        date = record["run_at"].to_s[0, 10]
        errors << "row reason must cite run_at date" if date.match?(/\A\d{4}-\d{2}-\d{2}\z/) && !reason.include?(date)
      when "fails-live", "not-proven", "partial"
        errors << "row cites missing live run record" if cites_record && record.nil?
      else
        errors << "unknown checklist status #{status.inspect}"
      end

      errors
    end

    def wire_capture_live_entries
      RpmsRpc::WireCapture::CATALOG.select(&:live?)
    end

    def unproven_readiness_keys(checklist_key, slices)
      results = replay_results_for_slices(slices)
      validate_raws = checklist_key == "Tribal.validate" ? slices.map { |s| load_fixture_raw(s[:fixture_name]) } : nil
      proven = proven_readiness_keys(checklist_key, results, validate_raws: validate_raws)
      readiness_keys_for(checklist_key) - proven
    end

    def load_fixture_raw(fixture_name)
      slice = TRIBAL_SLICE.find { |s| s[:fixture_name] == fixture_name }
      fail "unknown fixture #{fixture_name}" unless slice

      entry = catalog_entry_for_fixture(fixture_name)
      path = fixture_path_for(entry)
      RpmsRpc::WireCapture::Fixture.load_file(path).raw_return
    end

    def cia_reply_body(raw_return)
      bytes = raw_return.to_s.b
      rest = bytes.byteslice(1..) || "".b
      case rest.getbyte(0)
      when 0x00 then rest.byteslice(1..) || "".b
      when 0x01 then rest.byteslice(1..).to_s
      else rest.to_s
      end
    end

    def lister_data_rows(raw_return)
      body = cia_reply_body(raw_return)
      lines = body.split(/\r\n|\r|\n|\x1e/).map(&:strip).reject(&:empty?)
      data_at = lines.index("[Data]")
      return [] unless data_at

      rows = []
      lines[(data_at + 1)..].each do |line|
        break if line.start_with?("[")

        rows << line
      end
      rows
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
        Ddr.lister_param(file: Tribal::TRIBE_FILE, fields: Tribal::NAME_ONLY, part: "OTHER", xref: "B")
      when "tribal-communities"
        Ddr.lister_param(file: Tribal::COMMUNITY_FILE, fields: Tribal::COMMUNITY_FIELDS, part: "STONEHAM", xref: "B")
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

      comments = File.readlines(path, chomp: true, encoding: Encoding::UTF_8).take(5).select { |l| l.start_with?("#") }.join("\n")
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

  def test_tribal_lister_fixtures_use_other_and_stoneham_slices_without_real_tribe_names
    tribes_slice = TRIBAL_SLICE.find { |s| s[:fixture_name] == "tribal-tribes" }
    communities_slice = TRIBAL_SLICE.find { |s| s[:fixture_name] == "tribal-communities" }
    tribes_fixture = load_slice_fixture(tribes_slice)
    communities_fixture = load_slice_fixture(communities_slice)

    tribe_rows = self.class.lister_data_rows(tribes_fixture.raw_return)
    refute_empty tribe_rows, "tribal-tribes.yml must contain [Data] rows"
    tribe_rows.each do |row|
      _ien, name = row.split("^", 2)
      assert_equal "OTHER", name,
                   "tribal-tribes.yml must not commit real tribe names (expected catch-all OTHER only, got #{name.inspect})"
    end

    part = communities_fixture.inputs&.dig(0, "PART").to_s
    community_rows = self.class.lister_data_rows(communities_fixture.raw_return)
    refute_empty community_rows, "tribal-communities.yml must contain [Data] rows"
    community_rows.each do |row|
      name = row.split("^", 2)[1]
      assert name.to_s.start_with?(part),
             "community name #{name.inspect} in tribal-communities.yml must start with slice PART #{part.inspect}"
    end
  end

  def test_tribal_validate_fixtures_raw_sections_match_ddr_validator_contract
    valid_fixture = load_slice_fixture(TRIBAL_SLICE.find { |s| s[:fixture_name] == "tribal-validate-valid" })
    invalid_fixture = load_slice_fixture(TRIBAL_SLICE.find { |s| s[:fixture_name] == "tribal-validate-invalid" })
    valid_raw = valid_fixture.raw_return
    invalid_raw = invalid_fixture.raw_return

    assert_includes valid_raw, "[Data]"
    refute_includes valid_raw, "[BEGIN_diERRORS]"

    assert_includes invalid_raw, "[Data]"
    assert_includes invalid_raw, "[BEGIN_diERRORS]"
    invalid_rows = self.class.lister_data_rows(invalid_raw)
    assert_includes invalid_rows, "^", "invalid validator fixture must expose VAL^DIE failure marker ^ in [Data]"
  end

  def test_validate_access_denied_reply_does_not_count_as_valid_false_proof
    raw = "5\0Access denied for remote procedure.\r"
    row = tribal_validate_replay(raw, "12345")
    refute_nil row
    assert_equal false, row[:valid]
    refute self.class.validate_proof_from_raw?(row, raw, want_valid: false),
           "replies without [Data] must not prove :valid false branch"
  end

  def test_validate_internal_caret_does_not_prove_internal_or_external
    row = { valid: false, internal: "^", external: "" }
    refute self.class.validator_attribute_proven?(:internal, row)
    refute self.class.validator_attribute_proven?(:external, row)
  end

  def test_service_unit_empty_name_reply_proves_no_readiness_keys
    raw = "5\0[Data]\r9999999.22^1^.01^^\r"
    row = tribal_service_unit_replay(raw, 1)
    proven = self.class.proven_readiness_keys("Tribal.service_unit", [ row ])
    assert_empty proven,
                 "empty .01 external must leave service_unit not-proven (expected unproven #{SERVICE_UNIT_READINESS_KEYS.inspect})"
  end

  def test_tribes_lister_row_missing_ien_does_not_prove_ien
    raw = "5\0[Data]\r^SOMENAME\r"
    rows = tribal_tribes_replay(raw)
    proven = self.class.proven_readiness_keys("Tribal.tribes", [ rows ])
    refute_includes proven, :ien, "list :ien proves only on a positive Integer from the wire, not missing-IEN rows mapped to 0"
    assert_includes proven, :name
  end

  def test_evidence_rejects_unknown_community_placeholder
    refute RpmsRpc::WireCapture::Evidence.real_value?("UNKNOWN")
    refute RpmsRpc::WireCapture::Evidence.real_value?("unknown")
  end

  def test_pilot_chart_reads_fixtures_do_not_use_bare_unknown_as_wire_token
    chart_paths = CHART_READ_WIRE_FIXTURE_RPCS.map do |rpc|
      File.join(RpmsRpc::WireCapture::FIXTURES_DIR, "#{rpc.downcase.tr(" /", "--")}.yml")
    end
    bare_unknown = chart_paths.filter_map do |path|
      next unless File.file?(path)

      raw = YAML.safe_load_file(path)["raw_return"].to_s
      next if raw.match?(/\bUNKNOWN CODE\b/)

      File.basename(path) if raw.match?(/(?<![A-Z])UNKNOWN(?![A-Z])/)
    end
    assert_empty bare_unknown,
                 "pilot chart-read fixtures must not contain bare UNKNOWN placeholders " \
                 "(would change if Evidence rejects UNKNOWN; suspicious: #{bare_unknown.join(", ")})"
  end

  def test_tribal_enrollment_replayed_fixtures_leave_community_and_enrollment_number_unproven
    slices = self.class.slices_for_checklist_key("Tribal.enrollment")
    unproven = self.class.unproven_readiness_keys("Tribal.enrollment", slices)
    assert_includes unproven, :enrollment_number
    assert_includes unproven, :community,
                    "1118^UNKNOWN^UNKNOWN on DFN 2 is seed filler, not wire evidence of community"
  end

  def test_tribal_enrollment_checklist_documents_seed_data_gap_for_blank_enrollment_number
    rows = parse_checklist
    row = rows["Tribal.enrollment"]
    refute_nil row, "checklist must include Tribal.enrollment"
    assert_equal "partial", row[:status]
    assert_includes row[:unproven], "enrollment_number"
    assert_includes row[:unproven], "community"
    assert_match(/seed.?data gap/i, row[:reason])
    assert_match(/\.07|enrollment/i, row[:reason])
    assert_match(/1118|community/i, row[:reason])
    assert_match(/UNKNOWN/i, row[:reason])
    assert_match(/PROV123/, row[:reason])
  end

  def test_registration_update_eligibility_checklist_row
    rows = parse_checklist
    row = rows["Registration.update eligibility"]
    refute_nil row, "checklist must include Registration.update eligibility write row"
    assert_includes row[:reason], "test/live/registration_eligibility_update_live_test.rb"
    assert_match(/BENEFICIARY.*9999999\.25.*IEN\s*1.*OTHER|9999999\.25.*OTHER.*IEN\s*1/i, row[:reason],
                 "classification is proven only by filing the sole BENEFICIARY entry (IEN 1 OTHER) on this build")
    assert_match(/OTHER|seed.?data gap/i, row[:reason])
  end

  def test_registration_update_eligibility_checklist_row_consistent_with_live_run_record
    rows = parse_checklist
    row = rows["Registration.update eligibility"]
    refute_nil row, "checklist must include Registration.update eligibility write row"
    record = self.class.load_live_run_record
    errors = self.class.live_run_record_consistency_errors(row, record, pinned_build: PINNED_RELEASE)
    assert_empty errors, errors.join("; ")
  end

  def test_live_run_record_consistency_accepts_synthetic_pilot_ready_row
    record = self.class.synthetic_live_run_record
    row = self.class.synthetic_pilot_ready_eligibility_row(record)
    assert_empty self.class.live_run_record_consistency_errors(row, record, pinned_build: PINNED_RELEASE)
  end

  def test_live_run_record_consistency_rejects_pilot_ready_when_record_passed_false
    record = self.class.synthetic_live_run_record("passed" => false)
    row = self.class.synthetic_pilot_ready_eligibility_row(record)
    errors = self.class.live_run_record_consistency_errors(row, record, pinned_build: PINNED_RELEASE)
    refute_empty errors
    assert errors.any? { |e| e.include?("passed") }
  end

  def test_live_run_record_consistency_rejects_pilot_ready_when_failures_nonzero
    record = self.class.synthetic_live_run_record("failures" => 1)
    row = self.class.synthetic_pilot_ready_eligibility_row(record)
    refute_empty self.class.live_run_record_consistency_errors(row, record, pinned_build: PINNED_RELEASE)
  end

  def test_live_run_record_consistency_rejects_pilot_ready_on_build_mismatch
    record = self.class.synthetic_live_run_record("build" => "wrong-build-tag")
    row = self.class.synthetic_pilot_ready_eligibility_row(record)
    errors = self.class.live_run_record_consistency_errors(row, record, pinned_build: PINNED_RELEASE)
    assert errors.any? { |e| e.include?("build") }
  end

  def test_live_run_record_consistency_rejects_pilot_ready_when_run_id_not_cited
    record = self.class.synthetic_live_run_record
    row = self.class.synthetic_pilot_ready_eligibility_row(record)
    row = row.merge(reason: row[:reason].sub(record["run_id"], "not-cited"))
    refute_empty self.class.live_run_record_consistency_errors(row, record, pinned_build: PINNED_RELEASE)
  end

  def test_live_run_record_consistency_rejects_pilot_ready_when_run_date_not_cited
    record = self.class.synthetic_live_run_record
    row = self.class.synthetic_pilot_ready_eligibility_row(record)
    date = record["run_at"][0, 10]
    row = row.merge(reason: row[:reason].sub(date, "0000-00-00"))
    refute_empty self.class.live_run_record_consistency_errors(row, record, pinned_build: PINNED_RELEASE)
  end

  def test_live_run_record_consistency_rejects_pilot_ready_when_persona_not_cited
    record = self.class.synthetic_live_run_record
    row = self.class.synthetic_pilot_ready_eligibility_row(record)
    row = row.merge(reason: row[:reason].sub(record["persona"], "NOBODY"))
    refute_empty self.class.live_run_record_consistency_errors(row, record, pinned_build: PINNED_RELEASE)
  end

  def test_live_run_record_consistency_rejects_pilot_ready_when_record_nil
    row = self.class.synthetic_pilot_ready_eligibility_row(self.class.synthetic_live_run_record)
    refute_empty self.class.live_run_record_consistency_errors(row, nil, pinned_build: PINNED_RELEASE)
  end

  def test_live_run_record_consistency_accepts_fails_live_row_with_failed_record
    record = self.class.synthetic_live_run_record("passed" => false)
    row = { status: "fails-live", unproven: "none",
            reason: "honest downgrade cites #{self.class::LIVE_RUN_RECORD_REL}" }
    assert_empty self.class.live_run_record_consistency_errors(row, record, pinned_build: PINNED_RELEASE)
  end

  def test_live_run_record_consistency_accepts_fails_live_row_with_passed_record
    record = self.class.synthetic_live_run_record("passed" => true)
    row = { status: "fails-live", unproven: "none", reason: "downgrade without citing record" }
    assert_empty self.class.live_run_record_consistency_errors(row, record, pinned_build: PINNED_RELEASE)
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
    source = File.read(LIVE_ELIGIBILITY_SPEC, encoding: Encoding::UTF_8)
    refute_match(/INDIAN\/ALASKA NATIVE/, source,
                 "live spec must pick a classification from #9999999.25 on the build, not a missing name")
  end

  def test_live_eligibility_spec_covers_ag_eligibility_window_update_and_readback
    assert self.class.live_eligibility_spec_covers_window_eligibility_attrs?,
           "#{LIVE_ELIGIBILITY_SPEC} must write every WINDOW_ELIGIBILITY UPDATE_ATTRIBUTES key and read each back"
  end

  def test_live_eligibility_spec_guard_accepts_committed_live_spec_source
    source = File.read(LIVE_ELIGIBILITY_SPEC, encoding: Encoding::UTF_8)
    assert self.class.live_eligibility_spec_covers_window_eligibility_attrs?(source),
           "committed live spec must satisfy filed-attr and refute_equal guards"
  end

  def test_live_eligibility_spec_guard_rejects_no_op_mutant
    source = File.read(LIVE_ELIGIBILITY_SPEC, encoding: Encoding::UTF_8)
    mutant = self.class.live_eligibility_spec_no_op_mutant(source)
    refute self.class.live_eligibility_spec_covers_window_eligibility_attrs?(mutant),
           "hard-coded eligibility attrs without before_internal/refute_equal must not pass the guard"
  end

  def test_live_eligibility_spec_guard_rejects_mutant_without_assert_equal_expected_filed
    source = File.read(LIVE_ELIGIBILITY_SPEC, encoding: Encoding::UTF_8)
    mutant = self.class.live_eligibility_spec_mutant_delete_assert_equal(source)
    refute self.class.live_eligibility_spec_covers_window_eligibility_attrs?(mutant),
           "live spec without assert_equal expected, filed must not pass the guard"
  end

  def test_live_eligibility_spec_guard_rejects_mutant_without_expected_classification_pair
    source = File.read(LIVE_ELIGIBILITY_SPEC, encoding: Encoding::UTF_8)
    mutant = self.class.live_eligibility_spec_mutant_remove_expected_field(source, '"1111"', "classification")
    refute self.class.live_eligibility_spec_covers_window_eligibility_attrs?(mutant),
           "expected hash missing 1111 => classification must not pass the guard"
  end

  def test_live_eligibility_spec_guard_rejects_mutant_without_expected_tribe_pair
    source = File.read(LIVE_ELIGIBILITY_SPEC, encoding: Encoding::UTF_8)
    mutant = self.class.live_eligibility_spec_mutant_remove_expected_field(source, '"1108"', "tribe")
    refute self.class.live_eligibility_spec_covers_window_eligibility_attrs?(mutant),
           "expected hash missing 1108 => tribe must not pass the guard"
  end

  def test_live_eligibility_spec_guard_rejects_mutant_without_standing_readback_assert_equal
    source = File.read(LIVE_ELIGIBILITY_SPEC, encoding: Encoding::UTF_8)
    mutant = self.class.live_eligibility_spec_mutant_delete_standing_readback_assert_equal(source)
    refute self.class.live_eligibility_spec_covers_window_eligibility_attrs?(mutant),
           "bare standing.values_at without assert_equal must not pass the guard"
  end

  def test_live_eligibility_spec_guard_rejects_commented_standing_readback_assert_equal
    source = File.read(LIVE_ELIGIBILITY_SPEC, encoding: Encoding::UTF_8)
    mutant = self.class.live_eligibility_spec_mutant_comment_standing_readback_assert_equal(source)
    refute self.class.live_eligibility_spec_covers_window_eligibility_attrs?(mutant),
           "commented-out standing readback assert_equal must not pass the guard"
  end

  def test_live_eligibility_spec_guard_rejects_refute_nil_instead_of_standing_readback_assert_equal
    source = File.read(LIVE_ELIGIBILITY_SPEC, encoding: Encoding::UTF_8)
    mutant = self.class.live_eligibility_spec_mutant_refute_nil_standing_readback(source)
    refute self.class.live_eligibility_spec_covers_window_eligibility_attrs?(mutant),
           "refute_nil standing must not substitute for standing readback assert_equal"
  end

  def test_live_eligibility_spec_guard_rejects_registration_update_tribe_string_literal
    source = File.read(LIVE_ELIGIBILITY_SPEC, encoding: Encoding::UTF_8)
    mutant = self.class.live_eligibility_spec_mutant_registration_update_tribe_string_literal(source)
    refute self.class.live_eligibility_spec_covers_window_eligibility_attrs?(mutant),
           "Registration.update tribe: string literal must not pass tribe selection guard"
  end

  def test_live_eligibility_spec_guard_rejects_tribes_part_other_than_other
    source = File.read(LIVE_ELIGIBILITY_SPEC, encoding: Encoding::UTF_8)
    mutant = self.class.live_eligibility_spec_mutant_tribes_part_not_other(source)
    refute self.class.live_eligibility_spec_covers_window_eligibility_attrs?(mutant),
           "Tribal.tribes(part: ...) other than OTHER must not pass part literal guard"
  end

  def test_tribal_tribes_wire_fixture_uses_other_catch_all_only
    assert self.class.tribal_tribes_fixture_catch_all_other?,
           "tribal-tribes.yml must record part OTHER and list only OTHER tribe names in data rows"
  end

  def test_tribal_eligibility_replay_zero_internal_classification_ien_is_nil_and_unproven
    raw = "5\0[Data]\r9000001^2^1111^0^\r9000001^2^1112^^\r"
    row = tribal_eligibility_replay(raw, 2)
    refute_nil row
    assert_nil row[:classification_ien],
               "Tribal.internal_ien must return nil when wire internal is 0 (fail closed)"
    proven = self.class.proven_readiness_keys("Tribal.eligibility", [ row ])
    refute_includes proven, :classification_ien,
                    "classification_ien proves only on a positive Integer pointer, not 0"
  end

  def test_tribal_eligibility_replay_blank_internal_classification_ien_is_nil_and_unproven
    raw = "5\0[Data]\r9000001^2^1111^ ^\r9000001^2^1112^^\r"
    row = tribal_eligibility_replay(raw, 2)
    refute_nil row
    assert_nil row[:classification_ien],
               "Tribal.internal_ien must return nil when wire internal is blank"
    proven = self.class.proven_readiness_keys("Tribal.eligibility", [ row ])
    refute_includes proven, :classification_ien
  end

  def test_tribal_enrollment_replay_zero_internal_tribe_ien_is_nil_and_unproven
    raw = "5\0[Data]\r9000001^2^.07^^\r9000001^2^1108^0^OTHER\r9000001^2^1109^^\r9000001^2^1110^^\r9000001^2^1111^^\r9000001^2^1112^^\r9000001^2^1118^^\r"
    row = tribal_enrollment_replay(raw, 2)
    refute_nil row
    assert_nil row[:tribe_ien], "Tribal.internal_ien must return nil when wire internal is 0"
    proven = self.class.proven_readiness_keys("Tribal.enrollment", [ row ])
    refute_includes proven, :tribe_ien
  end

  def test_tribal_enrollment_replay_blank_internal_tribe_ien_is_nil_and_unproven
    raw = "5\0[Data]\r9000001^2^.07^^\r9000001^2^1108^ ^\r9000001^2^1109^^\r9000001^2^1110^^\r9000001^2^1111^^\r9000001^2^1112^^\r9000001^2^1118^^\r"
    row = tribal_enrollment_replay(raw, 2)
    refute_nil row
    assert_nil row[:tribe_ien], "Tribal.internal_ien must return nil when wire internal is blank"
    proven = self.class.proven_readiness_keys("Tribal.enrollment", [ row ])
    refute_includes proven, :tribe_ien
  end

  def test_wire_capture_exposes_cite_only_helper
    assert RpmsRpc::WireCapture.respond_to?(:cite_only?),
           "implement RpmsRpc::WireCapture.cite_only?(entry, tokens) for rake wire:capture and wire_capture_driver"
  end

  def test_cite_only_ddr_gets_entry_data_token_matches_only_ddr_gets_entry_data_fixture
    assert RpmsRpc::WireCapture.respond_to?(:cite_only?),
           "implement RpmsRpc::WireCapture.cite_only?(entry, tokens) for rake wire:capture and wire_capture_driver"

    token = [ "DDR GETS ENTRY DATA" ]
    gets_entries = RpmsRpc::WireCapture::CATALOG.select { |e| e.rpc == "DDR GETS ENTRY DATA" }
    refute_empty gets_entries
    gets_entries.each do |entry|
      slug = self.class.rpc_slug_for(entry)
      by_fixture = token.any? { |t| t == entry.fixture_name }
      by_rpc_slug = token.any? { |t| t == entry.rpc && entry.fixture_name == slug }
      expected = by_fixture || by_rpc_slug
      assert_equal expected, RpmsRpc::WireCapture.cite_only?(entry, token),
                   "CITE_ONLY=#{token.first.inspect} must not cite live tribal GETS captures " \
                   "(entry fixture #{entry.fixture_name.inspect})"
    end
  end

  def test_cite_only_fixture_slug_matches_only_that_catalog_entry
    assert RpmsRpc::WireCapture.respond_to?(:cite_only?)

    token = [ "tribal-enrollment" ]
    RpmsRpc::WireCapture::CATALOG.each do |entry|
      expected = entry.fixture_name == "tribal-enrollment"
      assert_equal expected, RpmsRpc::WireCapture.cite_only?(entry, token),
                   "CITE_ONLY=tribal-enrollment must match only that fixture, not #{entry.fixture_name}"
    end
  end

  def test_unmatched_cite_only_tokens_reports_ddr_lister_and_ddr_validator
    live = self.class.wire_capture_live_entries
    assert RpmsRpc::WireCapture.respond_to?(:unmatched_cite_only_tokens),
           "implement WireCapture.unmatched_cite_only_tokens(entries, tokens)"

    assert_equal [ "DDR LISTER" ], RpmsRpc::WireCapture.unmatched_cite_only_tokens(live, [ "DDR LISTER" ])
    assert_equal [ "DDR VALIDATOR" ], RpmsRpc::WireCapture.unmatched_cite_only_tokens(live, [ "DDR VALIDATOR" ])
    assert_empty RpmsRpc::WireCapture.unmatched_cite_only_tokens(live, [ "tribal-enrollment" ])
    assert_empty RpmsRpc::WireCapture.unmatched_cite_only_tokens(live, [ "DDR GETS ENTRY DATA" ])
    assert_equal [ "NO SUCH RPC" ],
                 RpmsRpc::WireCapture.unmatched_cite_only_tokens(live, [ "tribal-enrollment", "NO SUCH RPC" ])
  end

  def test_select_live_entries_raises_on_unmatched_cite_only_token
    assert RpmsRpc::WireCapture.respond_to?(:select_live_entries),
           "implement WireCapture.select_live_entries(catalog:, only:, cite_only:)"

    err = assert_raises(ArgumentError) do
      RpmsRpc::WireCapture.select_live_entries(catalog: RpmsRpc::WireCapture::CATALOG, only: "", cite_only: [ "DDR LISTER" ])
    end
    assert_match(/DDR LISTER/, err.message)
  end

  def test_select_live_entries_excludes_cited_fixture_but_keeps_other_live_entries
    assert RpmsRpc::WireCapture.respond_to?(:select_live_entries),
           "implement WireCapture.select_live_entries(catalog:, only:, cite_only:)"

    selected = RpmsRpc::WireCapture.select_live_entries(
      catalog: RpmsRpc::WireCapture::CATALOG, only: "", cite_only: [ "tribal-tribes" ]
    )
    names = selected.map(&:fixture_name)
    refute_includes names, "tribal-tribes"
    assert_includes names, "tribal-communities"
  end

  def test_select_live_entries_with_empty_cite_only_returns_all_live_entries
    assert RpmsRpc::WireCapture.respond_to?(:select_live_entries),
           "implement WireCapture.select_live_entries(catalog:, only:, cite_only:)"

    selected = RpmsRpc::WireCapture.select_live_entries(
      catalog: RpmsRpc::WireCapture::CATALOG, only: "", cite_only: []
    )
    assert_equal self.class.wire_capture_live_entries.map(&:fixture_name).sort, selected.map(&:fixture_name).sort
  end

  def test_wire_capture_driver_selects_entries_before_connect_without_cite_only_predicate
    src = File.read(WIRE_CAPTURE_DRIVER_PATH, mode: "rb").force_encoding(Encoding::UTF_8)
    assert_match(/RpmsRpc::WireCapture\.select_live_entries/, src,
                 "bin/wire_capture_driver.rb must filter live entries through select_live_entries")
    connect_at = src.index("client.connect")
    select_at = src.index("select_live_entries")
    refute_nil connect_at, "driver must connect to broker"
    refute_nil select_at, "driver must call select_live_entries"
    assert_operator select_at, :<, connect_at, "select_live_entries must run before client.connect"

    selection_block = src[/select_live_entries[\s\S]{0,400}/]
    refute_match(/cite_only\?/, selection_block,
                 "driver must not call cite_only? for entry selection (use select_live_entries)")
  end

  def test_wire_rake_aborts_unmatched_cite_only_before_container_run
    src = File.read(WIRE_RAKE_PATH, encoding: Encoding::UTF_8)
    assert_match(/unmatched_cite_only_tokens|select_live_entries/, src,
                 "lib/tasks/wire.rake must reject unmatched CITE_ONLY before starting capture")
    assert_match(/abort/, src, "wire.rake must abort when CITE_ONLY token matches no live catalog entry")
  end

  private

  def tribal_validate_replay(raw, value)
    with_cia_replay(raw) { Tribal.validate(value) }
  end

  def tribal_service_unit_replay(raw, ien)
    with_cia_replay(raw) { Tribal.service_unit(ien) }
  end

  def tribal_tribes_replay(raw)
    with_cia_replay(raw) { Tribal.tribes(part: "X") }
  end

  def tribal_eligibility_replay(raw, dfn)
    with_cia_replay(raw) { Tribal.eligibility(dfn) }
  end

  def tribal_enrollment_replay(raw, dfn)
    with_cia_replay(raw) { Tribal.enrollment(dfn) }
  end

  def with_cia_replay(raw)
    client = CiaFramedReplayClient.new(raw)
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = client }
    yield
  ensure
    RpmsRpc.reset!
  end
end
