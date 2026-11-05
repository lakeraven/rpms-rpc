# frozen_string_literal: true

require "minitest/autorun"
require "digest"
require "fileutils"
require "tmpdir"
require "yaml"
require "rpms_rpc"
require "rpms_rpc/live_summary"
require "rpms_rpc/wire_capture"
require "rpms_rpc/mappings"
require "rpms_rpc/api/scheduling"
require "rpms_rpc/api/ddr_fileman"

# Issue #565 / #224 scheduling write slice: pilot-ready wire evidence on the pinned build.
#
# Grading: pilot-ready iff signed_on_as == PROV123 and every effect is proven via
# read-back; partial iff PROV123 and some effects proven; not-proven otherwise.
# No-data write replies (BSDX CANCEL APPOINTMENT empty ERRORID row) prove nothing alone.
class RpmsRpc::PilotSchedulingWritesTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  LOCK_PATH = File.join(ROOT, "data/fingerprints/rpms-ops.lock.yml")
  CHECKLIST_PATH = File.join(ROOT, "docs/pilot_rpc_readiness.md")

  PINNED_RELEASE = RpmsRpc::LiveSummary.pinned_build(LOCK_PATH).freeze
  SCHEDULING_PERSONA = "PROV123"
  SYNTHETIC_RESOURCE = "ZZ PILOT SCHED CAPTURE"
  PATIENT_DFN = "3"

  SCHEDULING_WRITE_SLICE = [
    {
      rpc: "BSDX ADD NEW APPOINTMENT",
      mapping: :scheduling_add_appointment,
      api_method: :add_appointment,
      effects: %i[appointment_id start patient resource dpt_appt_clinic]
    },
    {
      rpc: "BSDX CHECKIN APPOINTMENT",
      mapping: :scheduling_checkin_appointment,
      api_method: :checkin_appointment,
      effects: %i[success checkin_time]
    },
    {
      rpc: "BSDX CANCEL APPOINTMENT",
      mapping: :scheduling_cancel_appointment,
      api_method: :cancel_appointment,
      effects: %i[success cancel_status cancel_reason cancelled_at]
    },
    {
      rpc: "BSDX NOSHOW",
      mapping: :scheduling_noshow_appointment,
      api_method: :mark_no_show,
      effects: %i[success noshow_flag noshow_status]
    }
  ].freeze

  HermeticFixture = Struct.new(:mapping_name, :source, :captured_data_rows, :path, keyword_init: true)

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

  RS = "\x1e"

  class DdrReplayClient
    def initialize(read_backs)
      @read_backs = Array(read_backs)
    end

    def with_context(_option) = yield

    def call_rpc(rpc, param)
      want = normalize_param(param)
      hit = @read_backs.find { |e| e["rpc"] == rpc && normalize_param(e["inputs"]) == want }
      raise "unexpected DDR replay #{rpc} #{want.inspect}" unless hit

      hit["raw_return"].to_s.split(/\r?\n/)
    end

    def normalize_param(param)
      case param
      when Hash then param.transform_keys(&:to_s).sort.to_h
      else param
      end
    end
  end

  class SchedulingInputsClient
    attr_reader :calls

    def initialize(reply_lines = [ "1^" ])
      @calls = []
      @reply_lines = reply_lines
    end

    def with_context(_option) = yield

    def call_rpc(rpc, *params)
      @calls << [ rpc, params.map(&:to_s) ]
      @reply_lines
    end
  end

  class << self
    def fixture_path_for(rpc)
      File.join(RpmsRpc::WireCapture::FIXTURES_DIR, "#{rpc.downcase.tr(" /", "--")}.yml")
    end

    def load_fixture_yaml(rpc)
      path = fixture_path_for(rpc)
      return nil unless File.file?(path)

      YAML.safe_load_file(path)
    end

    def wire_contract_violations(fixture)
      return [] if fixture.path.nil?

      mapping = RpmsRpc::DataMapper[fixture.mapping_name]
      RpmsRpc::WireCapture::Contract.check(mapping, fixture)
    end

    def canonical_fileman_datetime(value)
      text = value.to_s
      return text unless text.include?(".")

      date, time = text.split(".", 2)
      time = time.sub(/0+\z/, "")
      time.empty? ? date : "#{date}.#{time}"
    end

    def dpt_appt_iens(start_time, dfn)
      "#{canonical_fileman_datetime(start_time)},#{dfn},"
    end

    def read_back_field_internal(read_backs, file:, iens:, field:, flags: "I")
      client = DdrReplayClient.new(read_backs)
      RpmsRpc.reset!
      RpmsRpc.configure { |cfg| cfg.client = client }
      result = RpmsRpc::DdrFileman.gets_entry(file: file, iens: iens, fields: field, flags: flags)
      return nil if result.nil? || result[:error]

      key = field.start_with?(".") ? field : ".#{field}"
      result[:fields][key]&.dig(:internal) || result[:fields][field.delete(".")]&.dig(:internal)
    ensure
      RpmsRpc.reset!
    end

    def write_success?(slice, fixture, yaml)
      return false if RpmsRpc::WireCapture.error_reply?(yaml["raw_return"])

      mapping = RpmsRpc::DataMapper[slice[:mapping]]
      row = fixture.captured_data_rows.first.to_s
      mapped = mapping.parse_one(row) if row && !row.empty?
      case slice[:mapping]
      when :scheduling_add_appointment
        id = mapped&.dig(:appointment_id).to_i
        id.positive? && mapped[:error].to_s.empty?
      when :scheduling_checkin_appointment
        piece = row.split("^", -1).first.to_s
        piece.empty? || piece == "0"
      when :scheduling_cancel_appointment
        piece = row.split("^", -1).first.to_s
        piece.empty?
      when :scheduling_noshow_appointment
        mapped&.dig(:result).to_i == 1
      else
        false
      end
    end

    def expected_internal_for_effect(slice, effect, yaml)
      args = yaml.fetch("api_call").fetch("args")
      case effect
      when :appointment_id
        mapping = RpmsRpc::DataMapper[:scheduling_add_appointment]
        row = RpmsRpc::WireCapture::Fixture.new(yaml).captured_data_rows.first
        mapping.parse_one(row)[:appointment_id].to_s
      when :start
        canonical_fileman_datetime(args["start_time"])
      when :patient
        args["patient_dfn"].to_s
      when :resource
        (args["resource_ien"] || yaml.dig("setup", "resource_ien")).to_s
      when :dpt_appt_clinic
        read_back_field_internal(
          yaml["read_back"], file: "2", iens: dpt_appt_iens(args["start_time"], args["patient_dfn"]),
          field: ".01"
        )
      when :checkin_time
        canonical_fileman_datetime(args["checkin_time"])
      when :cancel_status
        args["type"].to_s
      when :cancel_reason
        args["reason"].to_s
      when :cancelled_at
        nil # proven by presence of any real FileMan datetime on .12, not a literal
      when :noshow_flag
        "1"
      when :noshow_status
        "N"
      when :success
        "true"
      else
        raise "unknown effect #{effect}"
      end
    end

    def effect_proven?(slice, effect, yaml, fixture)
      return false unless RpmsRpc::WireCapture::Evidence.real_value?(expected_internal_for_effect(slice, effect, yaml)) ||
                          effect == :success || effect == :cancelled_at

      case effect
      when :success
        return false unless write_success?(slice, fixture, yaml)

        if slice[:mapping] == :scheduling_cancel_appointment
          effect_proven?(slice, :cancel_status, yaml, fixture)
        else
          true
        end
      when :cancel_reason
        reason = yaml.dig("api_call", "args", "reason").to_s
        return false if reason.empty? || reason == "14"

        got = read_back_field_internal(yaml["read_back"], file: "2",
                                       iens: dpt_appt_iens(yaml.dig("api_call", "args", "start_time") ||
                                                           yaml.dig("setup", "start_time"),
                                                           yaml.dig("api_call", "args", "patient_dfn") || PATIENT_DFN),
                                       field: "16")
        RpmsRpc::WireCapture::Evidence.real_value?(got) && got == reason
      when :cancelled_at
        appt_ien = yaml.dig("api_call", "args", "appointment_ien") || yaml.dig("setup", "appointment_ien")
        got = read_back_field_internal(yaml["read_back"], file: "9002018.4", iens: "#{appt_ien},", field: ".12")
        RpmsRpc::WireCapture::Evidence.real_value?(got) && got.to_s.include?(".")
      when :cancel_status
        args = yaml.fetch("api_call").fetch("args")
        got = read_back_field_internal(
          yaml["read_back"], file: "2",
          iens: dpt_appt_iens(yaml.dig("setup", "start_time"), args["patient_dfn"] || PATIENT_DFN),
          field: "3"
        )
        got == args["type"].to_s
      when :checkin_time
        args = yaml.fetch("api_call").fetch("args")
        appt_ien = args["appointment_ien"]
        got = read_back_field_internal(yaml["read_back"], file: "9002018.4", iens: "#{appt_ien},", field: ".03")
        canonical_fileman_datetime(got) == canonical_fileman_datetime(args["checkin_time"])
      when :noshow_flag
        appt_ien = yaml.dig("api_call", "args", "appointment_ien")
        got = read_back_field_internal(yaml["read_back"], file: "9002018.4", iens: "#{appt_ien},", field: ".1")
        got == "1"
      when :noshow_status
        args = yaml.fetch("api_call").fetch("args")
        got = read_back_field_internal(
          yaml["read_back"], file: "2",
          iens: dpt_appt_iens(yaml.dig("setup", "start_time"), PATIENT_DFN),
          field: "3"
        )
        got == "N"
      when :appointment_id
        got = read_back_field_internal(yaml["read_back"], file: "9002018.4",
                                       iens: "#{expected_internal_for_effect(slice, :appointment_id, yaml)},",
                                       field: ".01")
        canonical_fileman_datetime(got) == expected_internal_for_effect(slice, :start, yaml)
      when :start
        appt_id = expected_internal_for_effect(slice, :appointment_id, yaml)
        got = read_back_field_internal(yaml["read_back"], file: "9002018.4", iens: "#{appt_id},", field: ".01")
        canonical_fileman_datetime(got) == expected_internal_for_effect(slice, :start, yaml)
      when :patient
        appt_id = expected_internal_for_effect(slice, :appointment_id, yaml)
        got = read_back_field_internal(yaml["read_back"], file: "9002018.4", iens: "#{appt_id},", field: ".05")
        got == expected_internal_for_effect(slice, :patient, yaml)
      when :resource
        appt_id = expected_internal_for_effect(slice, :appointment_id, yaml)
        got = read_back_field_internal(yaml["read_back"], file: "9002018.4", iens: "#{appt_id},", field: ".07")
        got == expected_internal_for_effect(slice, :resource, yaml)
      when :dpt_appt_clinic
        args = yaml.fetch("api_call").fetch("args")
        got = read_back_field_internal(
          yaml["read_back"], file: "2", iens: dpt_appt_iens(args["start_time"], args["patient_dfn"]),
          field: ".01"
        )
        RpmsRpc::WireCapture::Evidence.real_value?(got)
      else
        false
      end
    rescue StandardError
      false
    end

    def proven_effects(slice, yaml, fixture)
      slice[:effects].select { |effect| effect_proven?(slice, effect, yaml, fixture) }
    end

    def unproven_effects(slice, yaml, fixture)
      persona = yaml["signed_on_as"]
      return slice[:effects] if persona != SCHEDULING_PERSONA

      slice[:effects] - proven_effects(slice, yaml, fixture)
    end

    def format_unproven_list(effects)
      effects.empty? ? "none" : effects.map(&:to_s).sort.join(", ")
    end

    def expected_checklist_status(slice, yaml, fixture)
      persona = yaml["signed_on_as"]
      unproven = unproven_effects(slice, yaml, fixture)
      if persona != SCHEDULING_PERSONA || unproven.sort == slice[:effects].sort
        "not-proven"
      elsif unproven.empty?
        "pilot-ready"
      else
        "partial"
      end
    end
  end

  def parse_checklist
    assert File.file?(CHECKLIST_PATH),
           "missing docs/pilot_rpc_readiness.md — scheduling pilot status must be written for humans and CI"

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

    yaml = YAML.safe_load_file(path)
    fixture = RpmsRpc::WireCapture::Fixture.load_file(path)
    [ yaml, fixture ]
  end

  def test_pinned_release_is_the_issue_565_build
    assert_equal "bcer-9.0-20261012-e7923a4-ydb", PINNED_RELEASE
  end

  def test_each_scheduling_write_has_a_committed_wire_fixture
    missing = SCHEDULING_WRITE_SLICE.filter_map do |slice|
      path = self.class.fixture_path_for(slice[:rpc])
      File.basename(path) unless File.file?(path)
    end
    assert_empty missing,
                 "missing fixture(s) under test/fixtures/wire_captures/ — run rake wire:capture_writes: #{missing.join(", ")}"
  end

  def test_pilot_checklist_covers_every_scheduling_write_rpc
    rows = parse_checklist
    missing = SCHEDULING_WRITE_SLICE.map { |s| s[:rpc] } - rows.keys
    assert_empty missing,
                 "docs/pilot_rpc_readiness.md must list every scheduling write RPC (#{missing.join(", ")})"
  end

  def test_pilot_checklist_field_level_readiness_matches_committed_fixtures
    rows = parse_checklist
    failures = []
    SCHEDULING_WRITE_SLICE.each do |slice|
      row = rows[slice[:rpc]]
      failures << "#{slice[:rpc]}: missing checklist row" and next unless row

      yaml, fixture = load_slice_fixture(slice)
      expected_unproven = self.class.format_unproven_list(self.class.unproven_effects(slice, yaml, fixture))
      if row[:unproven] != expected_unproven
        failures << "#{slice[:rpc]} line #{row[:line]}: unproven #{row[:unproven].inspect}, " \
                     "expected #{expected_unproven.inspect}"
      end

      expected_status = self.class.expected_checklist_status(slice, yaml, fixture)
      if row[:status] != expected_status
        failures << "#{slice[:rpc]} line #{row[:line]}: status #{row[:status].inspect}, " \
                     "expected #{expected_status.inspect}"
      end
    end
    assert_empty failures, failures.join("\n  ")
  end

  def test_pilot_checklist_add_reason_names_prov123_refusal_and_seed_gap
    rows = parse_checklist
    row = rows["BSDX ADD NEW APPOINTMENT"]
    assert row, "checklist must list BSDX ADD NEW APPOINTMENT"
    assert_match(/PROV123/i, row[:reason])
    assert_match(/seed gap/i, row[:reason])
  end

  def test_pilot_checklist_cancel_reason_names_sent_reason_ien
    rows = parse_checklist
    row = rows["BSDX CANCEL APPOINTMENT"]
    assert row, "checklist must list BSDX CANCEL APPOINTMENT"
    yaml, = load_slice_fixture(SCHEDULING_WRITE_SLICE.find { |s| s[:rpc] == "BSDX CANCEL APPOINTMENT" })
    reason = yaml.dig("api_call", "args", "reason").to_s
    assert_match(/\b#{Regexp.escape(reason)}\b/, row[:reason]) if reason.match?(/\A\d+\z/)
  end

  def test_checkin_cancel_noshow_fixtures_signed_on_as_prov123
    failures = []
    [
      "BSDX CHECKIN APPOINTMENT",
      "BSDX CANCEL APPOINTMENT",
      "BSDX NOSHOW"
    ].each do |rpc|
      yaml = self.class.load_fixture_yaml(rpc)
      next failures << "#{rpc}: no fixture" unless yaml

      actual = yaml["signed_on_as"]
      if actual != SCHEDULING_PERSONA
        failures << "#{rpc}: signed_on_as #{actual.inspect}, expected #{SCHEDULING_PERSONA.inspect}"
      end
    end
    assert_empty failures, failures.join("\n  ")
  end

  def test_add_fixture_signed_on_as_sys123_with_persona_probe_for_prov123
    yaml = self.class.load_fixture_yaml("BSDX ADD NEW APPOINTMENT")
    assert yaml, "missing BSDX ADD NEW APPOINTMENT fixture"
    assert_equal "SYS123", yaml["signed_on_as"]
    probe = yaml["persona_probe"]
    assert probe, "ADD fixture must carry persona_probe for PROV123 refusal"
    assert_equal SCHEDULING_PERSONA, probe["signed_on_as"]
    assert probe["raw_return"], "persona_probe must record raw_return"
    assert_equal Digest::SHA256.hexdigest(probe["raw_return"]), probe["sha256"]
  end

  def test_committed_write_fixtures_are_write_captures_on_pinned_build
    failures = []
    SCHEDULING_WRITE_SLICE.each do |slice|
      yaml, fixture = load_slice_fixture(slice)
      failures << "#{slice[:rpc]}: write: true required" unless yaml["write"] == true
      failures << "#{slice[:rpc]}: release_tag #{fixture.release_tag.inspect}" if fixture.release_tag != PINNED_RELEASE
      unless %w[live-capture no-data].include?(fixture.source)
        failures << "#{slice[:rpc]}: source #{fixture.source.inspect}, expected live-capture or no-data"
      end
      failures << "#{slice[:rpc]}: routine-cite is never proof" if fixture.source == "routine-cite"
      read_back = yaml["read_back"]
      failures << "#{slice[:rpc]}: read_back must be non-empty" if read_back.nil? || read_back.empty?
    end
    assert_empty failures, failures.join("\n  ")
  end

  def test_committed_write_fixtures_pass_wire_contract
    failures = []
    SCHEDULING_WRITE_SLICE.each do |slice|
      _yaml, fixture = load_slice_fixture(slice)
      next unless fixture.source == "live-capture"

      self.class.wire_contract_violations(fixture).each do |violation|
        failures << "#{slice[:rpc]}: #{violation}"
      end
    end
    assert_empty failures, failures.join("\n  ")
  end

  def test_api_call_args_match_scheduling_module_inputs
    failures = []
    SCHEDULING_WRITE_SLICE.each do |slice|
      yaml, = load_slice_fixture(slice)
      api = yaml["api_call"]
      failures << "#{slice[:rpc]}: missing api_call" and next unless api

      client = SchedulingInputsClient.new
      RpmsRpc.reset!
      RpmsRpc.configure { |cfg| cfg.client = client }
      args = api["args"].transform_keys(&:to_sym)
      RpmsRpc::Scheduling.public_send(slice[:api_method], **args)
      expected_rpc = RpmsRpc::DataMapper[slice[:mapping]].rpc_name
      failures << "#{slice[:rpc]}: expected rpc #{expected_rpc}" unless client.calls.last&.first == expected_rpc
      failures << "#{slice[:rpc]}: inputs #{client.calls.last&.last.inspect} != fixture #{yaml["inputs"].inspect}" if
        client.calls.last&.last != Array(yaml["inputs"])
    ensure
      RpmsRpc.reset!
    end
    assert_empty failures, failures.join("\n  ")
  end

  def test_add_committed_fixture_proves_every_add_effect_for_sys123_capture
    slice = SCHEDULING_WRITE_SLICE.find { |s| s[:mapping] == :scheduling_add_appointment }
    yaml, fixture = load_slice_fixture(slice)
    assert_equal "SYS123", yaml["signed_on_as"]
    slice[:effects].each do |effect|
      assert self.class.effect_proven?(slice, effect, yaml, fixture),
             "ADD fixture as SYS123 must prove #{effect} from read-back bytes"
    end
  end

  def test_hermetic_cancel_reason_default_fourteen_is_unproven
    slice = SCHEDULING_WRITE_SLICE.find { |s| s[:mapping] == :scheduling_cancel_appointment }
    yaml = hermetic_cancel_fixture(reason: "14")
    fixture = hermetic_fixture(yaml, [ "" ])
    refute self.class.effect_proven?(slice, :cancel_reason, yaml, fixture)
    assert_includes self.class.unproven_effects(slice, yaml, fixture), :cancel_reason
  end

  def test_hermetic_cancel_blank_reason_is_unproven
    slice = SCHEDULING_WRITE_SLICE.find { |s| s[:mapping] == :scheduling_cancel_appointment }
    yaml = hermetic_cancel_fixture(reason: "")
    fixture = hermetic_fixture(yaml, [ "" ])
    refute self.class.effect_proven?(slice, :cancel_reason, yaml, fixture)
  end

  def test_hermetic_read_back_error_proves_no_read_back_effects
    slice = SCHEDULING_WRITE_SLICE.find { |s| s[:mapping] == :scheduling_checkin_appointment }
    yaml = hermetic_checkin_fixture(read_back_raw: "[ERROR]\n-1^bad\n")
    fixture = hermetic_fixture(yaml, [ "0^" ])
    refute self.class.effect_proven?(slice, :checkin_time, yaml, fixture)
    assert_equal "partial", self.class.expected_checklist_status(slice, yaml, fixture)
  end

  def test_hermetic_broker_error_write_reply_makes_success_unproven
    slice = SCHEDULING_WRITE_SLICE.find { |s| s[:mapping] == :scheduling_checkin_appointment }
    yaml = hermetic_checkin_fixture(
      raw_return: "8\x01-1^Access denied#{RS}#{RS}",
      sha256: Digest::SHA256.hexdigest("8\x01-1^Access denied#{RS}#{RS}")
    )
    fixture = hermetic_fixture(yaml, [])
    refute self.class.effect_proven?(slice, :success, yaml, fixture)
  end

  def test_hermetic_prov123_all_effects_proven_grades_pilot_ready
    slice = SCHEDULING_WRITE_SLICE.find { |s| s[:mapping] == :scheduling_checkin_appointment }
    yaml = hermetic_checkin_fixture
    fixture = hermetic_fixture(yaml, [ "0^" ])
    assert_equal slice[:effects].sort, self.class.proven_effects(slice, yaml, fixture).sort
    assert_equal "pilot-ready", self.class.expected_checklist_status(slice, yaml, fixture)
  end

  private

  def hermetic_fixture(yaml, data_rows)
    HermeticFixture.new(
      mapping_name: yaml["mapping"].to_sym,
      source: yaml["source"],
      captured_data_rows: data_rows,
      path: nil
    )
  end

  def hermetic_checkin_fixture(overrides = {})
    raw = overrides.fetch(:raw_return) { "8\x00T00020ERRORID^T00150MESSAGE#{RS}0^#{RS}" }
    read_raw = overrides.fetch(:read_back_raw) do
      "[Data]\n9002018.4^5,^.03^3270107.093\n"
    end
    data = {
      "rpc" => "BSDX CHECKIN APPOINTMENT",
      "mapping" => "scheduling_checkin_appointment",
      "kind" => "fields",
      "source" => "live-capture",
      "write" => true,
      "cite" => "CHECKIN^BSDX25 (hermetic)",
      "release_tag" => PINNED_RELEASE,
      "captured_at" => "2026-11-05T00:00:00Z",
      "signed_on_as" => SCHEDULING_PERSONA,
      "inputs" => [ "5", "3270107.093", "", "", "", "", "", "", "" ],
      "raw_return" => raw,
      "sha256" => overrides.fetch(:sha256) { Digest::SHA256.hexdigest(raw) },
      "pieces" => [ { "position" => 0, "attribute" => "error" } ],
      "api_call" => {
        "method" => "checkin_appointment",
        "args" => { "appointment_ien" => 5, "checkin_time" => "3270107.093" }
      },
      "setup" => { "start_time" => "3270107.09" },
      "read_back" => [
        {
          "rpc" => "DDR GETS ENTRY DATA",
          "inputs" => { "FILE" => "9002018.4", "IENS" => "5,", "FIELDS" => ".03", "FLAGS" => "I" },
          "raw_return" => read_raw,
          "sha256" => Digest::SHA256.hexdigest(read_raw)
        }
      ]
    }
    data
  end

  def hermetic_cancel_fixture(reason:)
    start = "3270107.09"
    raw = "8\x00T00020ERRORID#{RS}#{RS}"
    read_status = "[Data]\n2^#{PATIENT_DFN},#{start},^3^PC\n"
    read_reason = "[Data]\n2^#{PATIENT_DFN},#{start},^16^#{reason}\n"
    {
      "rpc" => "BSDX CANCEL APPOINTMENT",
      "mapping" => "scheduling_cancel_appointment",
      "kind" => "fields",
      "source" => "live-capture",
      "write" => true,
      "cite" => "APPDEL^BSDX08 (hermetic)",
      "release_tag" => PINNED_RELEASE,
      "captured_at" => "2026-11-05T00:00:00Z",
      "signed_on_as" => SCHEDULING_PERSONA,
      "inputs" => [ "5", "PC", reason, "" ],
      "raw_return" => raw,
      "sha256" => Digest::SHA256.hexdigest(raw),
      "pieces" => [ { "position" => 0, "attribute" => "error" } ],
      "api_call" => {
        "method" => "cancel_appointment",
        "args" => { "appointment_ien" => 5, "type" => "PC", "reason" => reason, "note" => nil }
      },
      "setup" => { "start_time" => start, "appointment_ien" => 5 },
      "read_back" => [
        {
          "rpc" => "DDR GETS ENTRY DATA",
          "inputs" => { "FILE" => "2", "IENS" => self.class.dpt_appt_iens(start, PATIENT_DFN), "FIELDS" => "3", "FLAGS" => "I" },
          "raw_return" => read_status,
          "sha256" => Digest::SHA256.hexdigest(read_status)
        },
        {
          "rpc" => "DDR GETS ENTRY DATA",
          "inputs" => { "FILE" => "2", "IENS" => "#{start},#{PATIENT_DFN},", "FIELDS" => "16", "FLAGS" => "I" },
          "raw_return" => read_reason,
          "sha256" => Digest::SHA256.hexdigest(read_reason)
        }
      ]
    }
  end
end
