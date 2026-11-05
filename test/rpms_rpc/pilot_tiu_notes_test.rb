# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "yaml"
require "digest"
require "open3"
require "timeout"
require "tmpdir"
require "rpms_rpc"
require "rpms_rpc/live_summary"
require "rpms_rpc/wire_capture"
require "rpms_rpc/mappings"
require "rpms_rpc/api/progress_note"
require "rpms_rpc/api/e_signature"

# Issue #564 / #224 (TIU note writes slice): pilot-ready wire evidence for
# TIU CREATE / LOCK / SET TEXT / GET TEXT / UNLOCK / SIGN on seed patient DFN 4.
#
# Failing tests only until the builder adds catalog write entries, NoteWriteFlow,
# write_evidence?, fixtures, and docs/pilot_rpc_readiness.md TIU rows.
class RpmsRpc::PilotTiuNotesTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  LOCK_PATH = File.join(ROOT, "data/fingerprints/rpms-ops.lock.yml")
  CHECKLIST_PATH = File.join(ROOT, "docs/pilot_rpc_readiness.md")

  PINNED_RELEASE = RpmsRpc::LiveSummary.pinned_build(LOCK_PATH).freeze
  PILOT_PERSONA = "PROV123"

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

  NOTE_IEN_IN_REASON = /\bnote (IEN )?\d+\b/

  LOCKED_ELSEWHERE = "1^ Another session has this record locked."
  ESIG_REFUSAL = "89250005^You have entered an incorrect Electronic Signature Code...Try again!"

  # ProgressNote.create("4", "4", "248") wire actuals (MAKE^TIUSRVP).
  CREATE_INPUTS = [ "4", "248", "", "", "4" ].freeze

  TIU_WRITE_SLICE = [
    { rpc: "TIU CREATE RECORD", mapping: :tiu_create_record, kind: "scalar",
      inputs: CREATE_INPUTS, evidence: :live_capture },
    { rpc: "TIU LOCK RECORD", mapping: :tiu_lock_record, kind: "scalar",
      inputs: :note_ien, evidence: :live_capture },
    { rpc: "TIU SET DOCUMENT TEXT", mapping: :tiu_set_document_text, kind: "scalar",
      inputs: :note_ien, evidence: :live_capture },
    { rpc: "TIU GET RECORD TEXT", mapping: :tiu_get_record_text, kind: "text_blob",
      inputs: :note_ien, evidence: :live_capture },
    { rpc: "TIU UNLOCK RECORD", mapping: :tiu_unlock_record, kind: "scalar",
      inputs: :note_ien, evidence: :live_capture },
    { rpc: "TIU SIGN RECORD", mapping: :tiu_sign_record, kind: "scalar",
      inputs: :note_ien, evidence: :routine_cite }
  ].freeze

  TIU_CHECKLIST_RPCS = TIU_WRITE_SLICE.map { |s| s[:rpc] }.freeze

  FIXTURES = RpmsRpc::WireCapture::Fixture.load_all.freeze

  class TiuProbeClient
    def initialize(raw_by_rpc)
      @raw_by_rpc = raw_by_rpc.transform_keys(&:to_s)
    end

    def call_rpc(rpc, *)
      @raw_by_rpc.fetch(rpc) { raise "unexpected RPC #{rpc}" }
    end
  end

  class << self
    def fixture_path_for(rpc)
      File.join(RpmsRpc::WireCapture::FIXTURES_DIR, "#{rpc.downcase.tr(" /", "--")}.yml")
    end

    def catalog_entry_for(rpc)
      RpmsRpc::WireCapture::CATALOG.find { |e| e.rpc == rpc }
    end

    def wire_contract_violations(fixture)
      mapping = RpmsRpc::DataMapper[fixture.mapping_name]
      RpmsRpc::WireCapture::Contract.check(mapping, fixture)
    end

    def normalize_cite(text)
      text.to_s.gsub(/\s+/, " ").strip
    end

    def fixture_signed_on_as(fixture)
      return nil unless fixture.path

      YAML.safe_load_file(fixture.path)["signed_on_as"]
    end

    def note_write_flow_defined?
      defined?(RpmsRpc::WireCapture::NoteWriteFlow)
    end

    def note_text!
      raise "NoteWriteFlow missing" unless note_write_flow_defined?

      RpmsRpc::WireCapture::NoteWriteFlow::NOTE_TEXT
    end

    def withheld_placeholder!
      raise "NoteWriteFlow missing" unless note_write_flow_defined?

      RpmsRpc::WireCapture::NoteWriteFlow::WITHHELD
    end

    def create_ien_from_fixture(fixture)
      raw = fixture.raw_return.to_s.sub(/\A\d+[\x00\x01]/, "")
      first = raw.split("^", 2).first.to_s
      return first if first.match?(/\A\d+\z/) && first.to_i.positive?

      nil
    end

    def expected_checklist_unproven(status)
      status == "pilot-ready" ? "none" : "success"
    end
  end

  FIXTURE_WRITE_EVIDENCE_NO_NOTE_IEN = [
    RpmsRpc::WireCapture::NoteWriteFlow::CREATE_RPC,
    RpmsRpc::WireCapture::NoteWriteFlow::SIGN_RPC
  ].freeze

  def write_evidence_kwargs_for_fixture(entry, fixture, note_body: nil)
    kwargs = {}
    unless FIXTURE_WRITE_EVIDENCE_NO_NOTE_IEN.include?(entry.rpc)
      kwargs[:note_ien] = fixture.inputs[0] if fixture.inputs&.any?
    end
    kwargs[:note_body] = note_body if note_body
    kwargs
  end

  def write_evidence_for_fixture?(entry, fixture, note_body: nil)
    write_evidence?(entry, fixture.raw_return, **write_evidence_kwargs_for_fixture(entry, fixture, note_body: note_body))
  end

  def write_evidence?(entry, raw, note_body: nil, note_ien: :__unset__)
    assert RpmsRpc::WireCapture.respond_to?(:write_evidence?),
           "RpmsRpc::WireCapture.write_evidence? missing"
    params = RpmsRpc::WireCapture.method(:write_evidence?).parameters
    if note_ien != :__unset__
      flunk "write_evidence? must accept note_ien: keyword" unless params.any? { |_, name| name == :note_ien }

      kwargs = { note_ien: note_ien }
      kwargs[:note_body] = note_body if note_body
      return RpmsRpc::WireCapture.write_evidence?(entry, raw, **kwargs)
    end
    if note_body
      RpmsRpc::WireCapture.write_evidence?(entry, raw, note_body: note_body)
    else
      RpmsRpc::WireCapture.write_evidence?(entry, raw)
    end
  end

  def write_refusal(**kwargs)
    params = RpmsRpc::WireCapture.method(:write_refusal).parameters.map(&:last)
    %i[access resolver only esig].each do |key|
      next unless kwargs.key?(key)

      flunk "write_refusal must accept #{key}:" unless params.include?(key)
    end
    RpmsRpc::WireCapture.write_refusal(**kwargs)
  end

  def write_refusal_ok_kwargs
    { writes: true, host: "127.0.0.1", container: nil, access: PILOT_PERSONA }
  end

  def note_text
    self.class.note_text!
  end

  def expected_checklist_status(_slice, fixture, entry)
    persona = self.class.fixture_signed_on_as(fixture)
    if fixture.source == "live-capture" &&
       persona == PILOT_PERSONA &&
       write_evidence_for_fixture?(entry, fixture, note_body: note_text)
      "pilot-ready"
    else
      "not-proven"
    end
  end

  def parse_checklist
    assert File.file?(CHECKLIST_PATH),
           "missing docs/pilot_rpc_readiness.md — TIU pilot status must be recorded"

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
    flunk "#{slice[:rpc]}: missing fixture #{path}" unless File.file?(path)

    RpmsRpc::WireCapture::Fixture.load_file(path)
  end

  def catalog_entry!(rpc)
    entry = self.class.catalog_entry_for(rpc)
    flunk "#{rpc}: no CatalogEntry in lib/rpms_rpc/wire_capture.rb" if entry.nil?
    entry
  end

  def assert_catalog_entry_write!(entry)
    assert entry.respond_to?(:write?), "CatalogEntry#write? missing"
    assert entry.write?, "#{entry.rpc}: catalog entry must be mode :write"
    refute entry.live?, "#{entry.rpc}: write entries must not be live? (driver must not call them)"
  end

  def framed(payload)
    "5\x00#{payload}"
  end

  def collapse_ws(text)
    text.to_s.gsub(/\s+/, " ").strip
  end

  def payload_without_cia_framing(raw)
    raw.to_s.sub(/\A\d+[\x00\x01]/, "")
  end

  def note_body_lines_after_header(text)
    lines = payload_without_cia_framing(text).split(/\r\n|\r|\n/, -1)
    blank = lines.index(&:empty?)
    return [] if blank.nil?

    lines[(blank + 1)..] || []
  end

  # Live TIU GET RECORD TEXT replies use CIA row grammar (\r or \r\n), not \n-only fixtures.
  def tiu_read_back_live_rows(note_body, row_sep)
    first_line = note_body.lines.first.to_s.chomp
    header = [
      "LOCAL TITLE: Progress Note",
      "STANDARD TITLE: PRIMARY CARE PROGRESS NOTE",
      "     URGENCY:   STATUS: UNSIGNED"
    ].join(row_sep)
    "#{header}#{row_sep}#{row_sep}#{first_line}#{row_sep}"
  end

  def tiu_read_back_header(row_sep)
    [
      "LOCAL TITLE: Progress Note",
      "STANDARD TITLE: PRIMARY CARE PROGRESS NOTE",
      "     URGENCY:   STATUS: UNSIGNED"
    ].join(row_sep)
  end

  # Same line pieces ProgressNote.update_text sends in TIUX("TEXT",n,0).
  def wrapped_note_text_lines(note_body)
    note_ien = "1"
    RpmsRpc.mock! { |m| m.seed_scalar(:tiu_set_document_text, note_ien, "#{note_ien}^1^1") }
    RpmsRpc::ProgressNote.update_text(note_ien, note_body)
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "TIU SET DOCUMENT TEXT" }
    flunk "TIU SET DOCUMENT TEXT was not called" unless call

    tiux = call[:params][1]
    tiux.select { |k, _| k.is_a?(Array) && k.first == "TEXT" }
        .sort_by { |k, _| k[1] }
        .map(&:last)
  ensure
    RpmsRpc.reset!
  end

  def tiu_read_back_full_wrapped(note_body, row_sep)
    header = tiu_read_back_header(row_sep)
    body_lines = wrapped_note_text_lines(note_body)
    ([ header, "" ] + body_lines).join(row_sep) + row_sep
  end

  def tiu_read_back_with_unwrapped_long_line(note_body, row_sep)
    header = tiu_read_back_header(row_sep)
    lines = note_body.lines.map(&:chomp)
    long = lines.find { |l| l.bytesize > RpmsRpc::ProgressNote::WRAP_WIDTH } || lines.last
    short = lines.reject { |l| l == long }
    short_blob = short.empty? ? "" : short.join("\n")
    body_lines = (short_blob.empty? ? [] : wrapped_note_text_lines(short_blob)) + [ long ]
    ([ header, "" ] + body_lines).join(row_sep) + row_sep
  end

  def tiu_read_back_missing_word(note_body, row_sep)
    full = tiu_read_back_full_wrapped(note_body, row_sep)
    words = note_body.split(/\s+/)
    drop = words.find { |w| w.length > 4 } || words.last
    full.sub(drop, "xyzzy")
  end

  def tiu_read_back_with_header(note_body)
    header = [
      "LOCAL TITLE: Progress Note",
      "STANDARD TITLE: Progress Note",
      "DATE OF NOTE: 3251105",
      "AUTHOR: PROVIDER,TEST",
      "URGENCY: routine"
    ].join("\n")
    body_lines = wrapped_note_text_lines(note_body)
    "#{header}\n\n#{body_lines.join("\n")}\n"
  end

  def tiu_read_back_with_header_first_line_only(note_body)
    header = [
      "LOCAL TITLE: Progress Note",
      "STANDARD TITLE: Progress Note",
      "DATE OF NOTE: 3251105",
      "AUTHOR: PROVIDER,TEST",
      "URGENCY: routine"
    ].join("\n")
    "#{header}\n\n#{note_body.lines.first.to_s.chomp}\n"
  end

  def fixture_pieces_yaml(entry)
    entry.pieces.map do |p|
      piece = { "position" => p.position, "attributes" => p.attributes }
      piece["fileman_type"] = p.fileman_type if p.fileman_type
      piece
    end
  end

  def build_live_capture_fixture_hash(entry, raw:, captured_at: "2026-11-01T12:00:00Z")
    {
      "rpc" => entry.rpc,
      "mapping" => entry.mapping.to_s,
      "kind" => entry.kind,
      "source" => "live-capture",
      "release_tag" => PINNED_RELEASE,
      "captured_at" => captured_at,
      "signed_on_as" => PILOT_PERSONA,
      "cite" => entry.cite,
      "inputs" => entry.inputs,
      "raw_return" => raw,
      "sha256" => Digest::SHA256.hexdigest(raw),
      "pieces" => fixture_pieces_yaml(entry)
    }
  end

  def write_fixture_file!(path, data)
    RpmsRpc::WireCapture::Fixture.new(data)
    File.write(path, YAML.dump(data))
  end

  # Open3 treats nil as unset — strip parent-process mode env so subprocess behavior is pinned.
  WIRE_CAPTURE_MODE_ENV_CLEAR = {
    "CONTAINER" => nil,
    "BROKER_HOST" => nil,
    "WRITES" => nil,
    "CITE_ONLY" => nil,
    "ONLY" => nil
  }.freeze

  def run_wire_capture_rake(env, timeout_s: nil)
    full_env = { "LANG" => "C.UTF-8" }.merge(WIRE_CAPTURE_MODE_ENV_CLEAR).merge(env)
    if timeout_s
      Timeout.timeout(timeout_s) do
        Open3.capture3(full_env, "bundle", "exec", "rake", "wire:capture", chdir: ROOT)
      end
    else
      Open3.capture3(full_env, "bundle", "exec", "rake", "wire:capture", chdir: ROOT)
    end
  rescue Timeout::Error
    flunk "wire:capture did not finish within #{timeout_s}s (likely hung before write refusal)"
  end

  def test_pinned_release_is_the_issue_224_build
    assert_equal "bcer-9.0-20261012-e7923a4-ydb", PINNED_RELEASE
  end

  def test_catalog_has_write_entries_for_every_tiu_rpc_with_non_blank_cite
    failures = []
    TIU_WRITE_SLICE.each do |slice|
      entry = self.class.catalog_entry_for(slice[:rpc])
      if entry.nil?
        failures << "#{slice[:rpc]}: no CatalogEntry"
        next
      end
      assert_catalog_entry_write!(entry) rescue failures << $!.message
      if self.class.normalize_cite(entry.cite).empty?
        failures << "#{slice[:rpc]}: cite must be non-blank (M routine citation)"
      end
      failures << "#{slice[:rpc]}: maps :#{entry.mapping}, expected :#{slice[:mapping]}" if entry.mapping != slice[:mapping]
      failures << "#{slice[:rpc]}: kind #{entry.kind.inspect}, expected #{slice[:kind].inspect}" if entry.kind != slice[:kind]
    end
    assert_empty failures, "TIU write catalog gaps:\n  #{failures.join("\n  ")}"
  end

  def test_write_catalog_create_entry_inputs_match_progress_note_create
    entry = catalog_entry!("TIU CREATE RECORD")
    assert_catalog_entry_write!(entry)
    assert_equal CREATE_INPUTS, entry.inputs
  end

  def test_wire_capture_driver_selects_only_live_entries_so_write_rpc_never_runs
    live_rpcs = RpmsRpc::WireCapture::CATALOG.select(&:live?).map(&:rpc)
    TIU_CHECKLIST_RPCS.each do |rpc|
      refute_includes live_rpcs, rpc,
                      "#{rpc} must not be live? — bin/wire_capture_driver.rb calls only live entries"
    end
  end

  def test_write_evidence_accepts_success_replies_judged_by_public_api
    assert RpmsRpc::WireCapture.respond_to?(:write_evidence?), "write_evidence? missing"

    create_entry = catalog_entry!("TIU CREATE RECORD")
    lock_entry = catalog_entry!("TIU LOCK RECORD")
    set_entry = catalog_entry!("TIU SET DOCUMENT TEXT")
    unlock_entry = catalog_entry!("TIU UNLOCK RECORD")
    sign_entry = catalog_entry!("TIU SIGN RECORD")
    get_entry = catalog_entry!("TIU GET RECORD TEXT")

    note_ien = "6"
    body = note_text

    assert write_evidence?(create_entry, framed(note_ien)),
           "create success IEN must be write evidence"
    assert write_evidence?(lock_entry, framed("0"), note_ien: note_ien),
           "lock held (0) must be write evidence"
    assert write_evidence?(set_entry, framed("#{note_ien}^1^1"), note_ien: note_ien),
           "set-text acknowledgement must match note_ien"
    refute write_evidence?(set_entry, framed("12^1^1"), note_ien: note_ien),
           "set-text reply IEN must match note_ien"
    refute write_evidence?(set_entry, framed("#{note_ien}^1^1")),
           "set-text without note_ien must fail closed"
    assert write_evidence?(unlock_entry, framed("0")),
           "unlock success must be write evidence"
    assert write_evidence?(sign_entry, framed("0")),
           "sign success must be write evidence"
    read_back = tiu_read_back_full_wrapped(body, "\n")
    assert write_evidence?(get_entry, framed(read_back), note_body: body),
           "read-back must prove every NOTE_TEXT line, wrapped within WRAP_WIDTH"
    assert write_evidence?(get_entry, framed(tiu_read_back_full_wrapped(body, "\r")), note_body: body),
           "read-back with \\r row separators must be write evidence"
    assert write_evidence?(get_entry, framed(tiu_read_back_full_wrapped(body, "\r\n")), note_body: body),
           "read-back with \\r\\n row separators must be write evidence"
  end

  def test_write_evidence_read_back_rejects_partial_or_unwrapped_bodies
    get_entry = catalog_entry!("TIU GET RECORD TEXT")
    body = note_text
    row_sep = "\r"

    first_only = tiu_read_back_live_rows(body, row_sep)
    refute write_evidence?(get_entry, framed(first_only), note_body: body),
           "first NOTE_TEXT line alone must not be evidence"

    long_line = body.lines.find { |l| l.bytesize > RpmsRpc::ProgressNote::WRAP_WIDTH }
    skip "NOTE_TEXT has no line longer than WRAP_WIDTH" unless long_line

    unwrapped = tiu_read_back_with_unwrapped_long_line(body, row_sep)
    refute write_evidence?(get_entry, framed(unwrapped), note_body: body),
           "body line over WRAP_WIDTH must not be evidence"

    missing_word = tiu_read_back_missing_word(body, row_sep)
    refute write_evidence?(get_entry, framed(missing_word), note_body: body),
           "body missing a NOTE_TEXT word must not be evidence"
  end

  def test_write_evidence_rejects_errors_empty_and_refused_writes
    assert RpmsRpc::WireCapture.respond_to?(:write_evidence?), "write_evidence? missing"

    create_entry = catalog_entry!("TIU CREATE RECORD")
    lock_entry = catalog_entry!("TIU LOCK RECORD")
    set_entry = catalog_entry!("TIU SET DOCUMENT TEXT")
    sign_entry = catalog_entry!("TIU SIGN RECORD")
    get_entry = catalog_entry!("TIU GET RECORD TEXT")
    body = note_text

    refute write_evidence?(create_entry, framed("-1^Application context denied"))
    refute write_evidence?(create_entry, "5\x01Access denied")
    refute write_evidence?(create_entry, framed(""))
    refute write_evidence?(create_entry, framed("0^Patient & Visit required."))
    refute write_evidence?(lock_entry, framed(LOCKED_ELSEWHERE))
    refute write_evidence?(set_entry, framed("0^0^0^Invalid text block header"))
    refute write_evidence?(sign_entry, framed(ESIG_REFUSAL))
    refute write_evidence?(get_entry, framed(""), note_body: body)
    refute write_evidence?(get_entry, framed("LOCAL TITLE: only\n"), note_body: body)
    cr_header = [
      "LOCAL TITLE: Progress Note",
      "STANDARD TITLE: PRIMARY CARE PROGRESS NOTE",
      "     URGENCY:   STATUS: UNSIGNED"
    ].join("\r")
    read_back_cr_without_note = "#{cr_header}\r\runrelated read-back line without NOTE_TEXT\r"
    refute write_evidence?(get_entry, framed(read_back_cr_without_note), note_body: body)
  end

  def test_write_refusal_requires_loopback_host_and_host_mode
    assert RpmsRpc::WireCapture.respond_to?(:write_refusal), "WireCapture.write_refusal missing"
    persona = { access: PILOT_PERSONA }

    [ false, nil ].each do |writes|
      assert_nil write_refusal(
        writes: writes, host: "10.0.0.5", container: "rpms-ydb-9.0", access: "REALCODE"
      ), "writes #{writes.inspect} must not be refused (access ignored on reads)"
      assert_nil write_refusal(
        writes: writes, host: "127.0.0.1", container: nil, access: PILOT_PERSONA
      ), "writes #{writes.inspect} must not be refused"
    end

    %w[127.0.0.1 localhost ::1 127.0.0.2].each do |host|
      assert_nil write_refusal(
        writes: true, host: host, container: nil, **persona
      ), "loopback #{host} in host mode (no CONTAINER) must allow writes"
      assert_nil write_refusal(
        writes: true, host: host, container: "", **persona
      ), "empty CONTAINER is unset — same as host mode"
    end

    off_host = write_refusal(
      writes: true, host: "10.0.0.5", container: nil, **persona
    )
    refute_nil off_host
    assert_match(/loopback/i, off_host)

    doc_test_net = write_refusal(
      writes: true, host: "192.0.2.1", container: nil, **persona
    )
    refute_nil doc_test_net
    assert_match(/loopback/i, doc_test_net)

    in_container = write_refusal(
      writes: true, host: "127.0.0.1", container: "rpms-ydb-9.0", **persona
    )
    refute_nil in_container
    assert_match(/CONTAINER/i, in_container)

    [ nil, "" ].each do |host|
      refused = write_refusal(
        writes: true, host: host, container: nil, **persona
      )
      refute_nil refused, "writes with host #{host.inspect} must be refused"
      assert_match(/loopback/i, refused)
    end

    unresolvable = write_refusal(
      writes: true, host: "host.invalid", container: nil, **persona
    )
    refute_nil unresolvable
    assert_match(/loopback/i, unresolvable)

    fake_localhost = write_refusal(
      writes: true,
      host: "localhost",
      container: nil,
      access: PILOT_PERSONA,
      resolver: ->(_host) { [ "10.0.0.5" ] }
    )
    refute_nil fake_localhost
    assert_match(/loopback/i, fake_localhost)
  end

  def test_write_refusal_requires_synthetic_persona_for_writes
    refusal = write_refusal(
      writes: true, host: "127.0.0.1", container: nil, access: "NOT-A-README-PERSONA"
    )
    refute_nil refusal
    refute_includes refusal, "NOT-A-README-PERSONA"
    refute_includes refusal, "NOT"

    assert_nil write_refusal(
      writes: true, host: "127.0.0.1", container: nil, access: "SYS123"
    )
    assert_nil write_refusal(
      writes: true, host: "127.0.0.1", container: nil, access: PILOT_PERSONA
    )
  end

  def test_write_refusal_rejects_only_naming_one_catalog_rpc_on_write_run
    write_only = write_refusal(**write_refusal_ok_kwargs, only: "TIU CREATE RECORD")
    refute_nil write_only
    assert_match(/ONLY/i, write_only)
    assert_match(/TIU/i, write_only)
    assert_match(/together/i, write_only)

    read_only = write_refusal(**write_refusal_ok_kwargs, only: "ORQQVI VITALS")
    refute_nil read_only
    assert_match(/ONLY/i, read_only)
    assert_match(/TIU/i, read_only)

    assert_nil write_refusal(**write_refusal_ok_kwargs, only: nil)
    assert_nil write_refusal(**write_refusal_ok_kwargs, only: "")
  end

  def test_write_refusal_validates_esig_shape_before_socket
    esig_ok = "synthetic-esig-77"
    assert_nil write_refusal(**write_refusal_ok_kwargs, esig: nil)
    assert_nil write_refusal(**write_refusal_ok_kwargs, esig: "")
    assert_nil write_refusal(**write_refusal_ok_kwargs, esig: esig_ok)

    blank = write_refusal(**write_refusal_ok_kwargs, esig: " ")
    refute_nil blank
    refute_includes blank, " "

    short = write_refusal(**write_refusal_ok_kwargs, esig: "1")
    refute_nil short
    refute_includes short, "1"

    too_long = "synthetic-esig-777777"
    assert_equal 21, too_long.length
    long_refusal = write_refusal(**write_refusal_ok_kwargs, esig: too_long)
    refute_nil long_refusal
    refute_includes long_refusal, too_long
  end

  def test_write_refusal_rejects_esig_with_leading_or_trailing_whitespace
    esig_ok = "abcdef"
    assert_equal 6, esig_ok.length
    padded = "  #{esig_ok}  "
    refusal = write_refusal(**write_refusal_ok_kwargs, esig: padded)
    refute_nil refusal,
               "esig with surrounding whitespace must be refused (field 20.4 stores the exact code, not strip)"
    refute_includes refusal, esig_ok
    refute_includes refusal, padded.strip
    refute_includes refusal, " "
  end

  def test_normalize_only_treats_blank_values_as_unset
    assert RpmsRpc::WireCapture.respond_to?(:normalize_only),
           "WireCapture.normalize_only missing (blank ONLY must not filter every catalog entry)"
    assert_nil RpmsRpc::WireCapture.normalize_only(nil)
    assert_nil RpmsRpc::WireCapture.normalize_only("")
    assert_nil RpmsRpc::WireCapture.normalize_only(" ")
    assert_nil RpmsRpc::WireCapture.normalize_only("  \t  ")
    assert_equal "ORQQVI VITALS", RpmsRpc::WireCapture.normalize_only("ORQQVI VITALS")
    assert_equal "ORQQVI VITALS", RpmsRpc::WireCapture.normalize_only("  ORQQVI VITALS  ")
  end

  def test_wire_rake_fixture_loop_uses_normalize_only
    path = File.expand_path("../../lib/tasks/wire.rake", __dir__)
    src = File.binread(path).force_encoding(Encoding::UTF_8)
    assert_match(/\bnormalize_only\b/, src,
                 "lib/tasks/wire.rake must normalize ONLY before the catalog fixture loop")
  end

  def test_write_capture_source_labels_live_capture_or_skips_write_entries
    assert RpmsRpc::WireCapture.respond_to?(:write_capture_source),
           "RpmsRpc::WireCapture.write_capture_source missing"

    create_entry = catalog_entry!("TIU CREATE RECORD")
    sign_entry = catalog_entry!("TIU SIGN RECORD")
    get_entry = catalog_entry!("TIU GET RECORD TEXT")
    body = note_text
    read_back = tiu_read_back_with_header(body)

    assert_equal "live-capture",
                 RpmsRpc::WireCapture.write_capture_source(create_entry, framed("7"))
    assert_nil RpmsRpc::WireCapture.write_capture_source(create_entry, framed("0^Patient & Visit required."))
    assert_nil RpmsRpc::WireCapture.write_capture_source(create_entry, framed("")),
               "empty create reply must not be labelled live-capture"

    assert_equal "live-capture",
                 RpmsRpc::WireCapture.write_capture_source(get_entry, framed(read_back), note_body: body)
    partial = tiu_read_back_with_header_first_line_only(body)
    assert_nil RpmsRpc::WireCapture.write_capture_source(get_entry, framed(partial), note_body: body)
    assert_nil RpmsRpc::WireCapture.write_capture_source(get_entry, framed("LOCAL TITLE: only\n"), note_body: body)
    assert_nil RpmsRpc::WireCapture.write_capture_source(sign_entry, framed(ESIG_REFUSAL)),
               "incorrect esig reply must not be labelled live-capture"
  end

  def test_wire_capture_rake_keeps_existing_live_capture_write_fixture_when_nothing_captured
    entry = catalog_entry!("TIU CREATE RECORD")
    raw = "5\x007"
    data = build_live_capture_fixture_hash(entry, raw: raw)

    Dir.mktmpdir do |dir|
      path = self.class.fixture_path_for(entry.rpc)
      path = File.join(dir, File.basename(path))
      write_fixture_file!(path, data)
      before = File.binread(path)

      env = {
        "WIRE_FIXTURES_DIR" => dir,
        "ONLY" => entry.rpc,
        "RELEASE" => PINNED_RELEASE
      }
      out, err, status = run_wire_capture_rake(env)
      assert status.success?, "wire:capture must succeed when preserving fixtures:\n#{out}\n#{err}"
      assert_equal before, File.binread(path),
                   "live-capture write fixture must not be rewritten as routine-cite when the run captured nothing"
    end
  end

  def test_wire_capture_rake_writes_routine_cite_for_sign_when_nothing_captured
    entry = catalog_entry!("TIU SIGN RECORD")

    Dir.mktmpdir do |dir|
      env = {
        "WIRE_FIXTURES_DIR" => dir,
        "ONLY" => entry.rpc,
        "RELEASE" => PINNED_RELEASE
      }
      out, err, status = run_wire_capture_rake(env)
      assert status.success?, "wire:capture must write routine-cite sign fixture:\n#{out}\n#{err}"

      path = File.join(dir, File.basename(self.class.fixture_path_for(entry.rpc)))
      assert File.file?(path), "expected #{path} to be written"
      data = YAML.safe_load_file(path)
      assert_equal "routine-cite", data["source"]
      refute data.key?("raw_return"), "routine-cite sign fixture must not claim raw_return"
      refute data.key?("signed_on_as"), "routine-cite sign fixture must not carry signed_on_as"
    end
  end

  def test_wire_capture_rake_whitespace_only_writes_routine_cite_fixtures_like_unset_only
    entry = catalog_entry!("TIU SIGN RECORD")

    Dir.mktmpdir do |dir|
      env = {
        "WIRE_FIXTURES_DIR" => dir,
        "ONLY" => " ",
        "RELEASE" => PINNED_RELEASE
      }
      out, err, status = run_wire_capture_rake(env)
      assert status.success?,
             "wire:capture with ONLY=' ' must succeed like unset ONLY (no broker, routine-cite only):\n#{out}\n#{err}"

      path = File.join(dir, File.basename(self.class.fixture_path_for(entry.rpc)))
      assert File.file?(path),
             "ONLY=' ' must not skip every catalog entry; expected routine-cite sign fixture at #{path}"
      data = YAML.safe_load_file(path)
      assert_equal "routine-cite", data["source"]
    end
  end

  def test_wire_capture_rake_refuses_off_loopback_host_when_writes_enabled
    Dir.mktmpdir do |dir|
      env = {
        "WIRE_FIXTURES_DIR" => dir,
        "WRITES" => "1",
        "BROKER_HOST" => "192.0.2.1",
        "RELEASE" => PINNED_RELEASE
      }
      out, err, status = run_wire_capture_rake(env, timeout_s: 30)
      combined = "#{out}#{err}"
      refute status.success?, "wire:capture must abort for off-loopback WRITES=1:\n#{combined}"
      assert_match(/loopback/i, combined)
      assert_empty Dir.glob(File.join(dir, "*.yml")), "refused run must not write fixtures"
    end
  end

  def test_each_tiu_write_has_a_committed_wire_fixture
    missing = TIU_WRITE_SLICE.filter_map do |slice|
      path = self.class.fixture_path_for(slice[:rpc])
      File.basename(path) unless File.file?(path)
    end
    assert_empty missing,
                 "missing TIU fixture(s) — capture with WRITES=1 as PROV123: #{missing.join(", ")}"
  end

  def test_live_capture_tiu_fixtures_are_provenance_stamped_and_pass_contract
    failures = []
    create_fixture = nil
    TIU_WRITE_SLICE.each do |slice|
      fixture = load_slice_fixture(slice)
      entry = catalog_entry!(slice[:rpc])

      case slice[:evidence]
      when :live_capture
        unless fixture.source == "live-capture"
          failures << "#{slice[:rpc]}: source #{fixture.source.inspect}, expected live-capture"
        end
        if fixture.release_tag != PINNED_RELEASE
          failures << "#{slice[:rpc]}: release_tag #{fixture.release_tag.inspect}, expected #{PINNED_RELEASE}"
        end
        if self.class.fixture_signed_on_as(fixture) != PILOT_PERSONA
          failures << "#{slice[:rpc]}: signed_on_as must be #{PILOT_PERSONA}"
        end
        unless write_evidence_for_fixture?(entry, fixture, note_body: note_text)
          failures << "#{slice[:rpc]}: raw_return must pass write_evidence?"
        end
        self.class.wire_contract_violations(fixture).each do |violation|
          failures << "#{slice[:rpc]}: #{violation}"
        end
        create_fixture = fixture if slice[:mapping] == :tiu_create_record
      when :routine_cite
        failures << "#{slice[:rpc]}: must be routine-cite (seed gap on signature), got #{fixture.source.inspect}" unless fixture.source == "routine-cite"
        failures << "#{slice[:rpc]}: routine-cite must not carry raw_return" unless fixture.raw_return.nil?
      end

      fixture_cite = self.class.normalize_cite(fixture.cite)
      catalog_cite = self.class.normalize_cite(entry.cite)
      failures << "#{slice[:rpc]}: fixture cite must match catalog" if fixture_cite != catalog_cite
    end

    refute_nil create_fixture, "TIU CREATE RECORD fixture required for IEN chaining"
    create_ien = self.class.create_ien_from_fixture(create_fixture)
    refute_nil create_ien, "create fixture must return a positive IEN"

    flow_fixtures = TIU_WRITE_SLICE.select { |s| s[:evidence] == :live_capture }.map { |s| load_slice_fixture(s) }
    captured_times = flow_fixtures.map(&:captured_at).uniq
    failures << "live TIU fixtures must share one captured_at (one flow), got #{captured_times.inspect}" if captured_times.size != 1

    flow_fixtures.each do |fixture|
      next if fixture.mapping_name == :tiu_create_record

      inputs = fixture.inputs
      failures << "#{fixture.rpc}: inputs[0] must be create IEN #{create_ien}, got #{inputs.inspect}" if inputs[0].to_s != create_ien.to_s
    end

    get_fixture = flow_fixtures.find { |f| f.mapping_name == :tiu_get_record_text }
    if get_fixture
      body = note_text
      payload = payload_without_cia_framing(get_fixture.raw_return)
      body_lines = note_body_lines_after_header(payload)
      long_line = body.lines.find { |l| l.bytesize > RpmsRpc::ProgressNote::WRAP_WIDTH }
      first_line = body.lines.first.to_s.strip

      if body_lines.empty?
        failures << "TIU GET RECORD TEXT must include note body lines after the server header blank line"
      else
        failures << "read-back body must include NOTE_TEXT first line" unless body_lines.any? { |l| l.include?(first_line) }
        if long_line
          joined = collapse_ws(body_lines.join(" "))
          expected = collapse_ws(long_line)
          failures << "read-back body must contain wrapped NOTE_TEXT long line" unless joined.include?(expected)
        end
        body_lines.each do |line|
          next if line.empty?

          if line.bytesize > RpmsRpc::ProgressNote::WRAP_WIDTH
            failures << "note body line exceeds WRAP_WIDTH: #{line.bytesize} bytes"
          end
        end
      end
    end

    assert_empty failures, failures.join("\n  ")
  end

  def test_tiu_sign_fixture_is_routine_cite_without_live_signature_proof
    slice = TIU_WRITE_SLICE.find { |s| s[:rpc] == "TIU SIGN RECORD" }
    fixture = load_slice_fixture(slice)
    assert_equal "routine-cite", fixture.source
    data = YAML.safe_load_file(fixture.path)
    refute data.key?("raw_return"), "sign fixture must not claim a live raw (PROV123 has no field 20.4 code)"
  end

  def test_no_wire_fixture_stores_a_literal_signature_code_for_tiu_sign_record
    flunk "NoteWriteFlow missing" unless self.class.note_write_flow_defined?

    withheld = self.class.withheld_placeholder!
    failures = []
    FIXTURES.each do |fixture|
      next unless fixture.rpc == "TIU SIGN RECORD"

      inputs = fixture.inputs
      next if inputs.nil? || inputs.length < 2

      if inputs[1] != withheld
        failures << "#{File.basename(fixture.path)}: inputs[1] must be WITHHELD, got #{inputs[1].inspect}"
      end
    end
    assert_empty failures, failures.join("\n  ")
  end

  def test_pilot_checklist_covers_every_tiu_rpc
    rows = parse_checklist
    missing = TIU_CHECKLIST_RPCS - rows.keys
    assert_empty missing,
                 "docs/pilot_rpc_readiness.md must list every TIU RPC (#{missing.join(", ")})"
  end

  def test_pilot_checklist_tiu_rows_match_fixture_derived_grading
    rows = parse_checklist
    failures = []
    TIU_WRITE_SLICE.each do |slice|
      row = rows[slice[:rpc]]
      failures << "#{slice[:rpc]}: missing checklist row" unless row
      next unless row

      fixture = load_slice_fixture(slice)
      entry = catalog_entry!(slice[:rpc])
      expected_status = expected_checklist_status(slice, fixture, entry)
      expected_unproven = self.class.expected_checklist_unproven(expected_status)

      if row[:status] != expected_status
        failures << "#{slice[:rpc]} line #{row[:line]}: status #{row[:status].inspect}, expected #{expected_status.inspect}"
      end
      if row[:unproven] != expected_unproven
        failures << "#{slice[:rpc]} line #{row[:line]}: unproven #{row[:unproven].inspect}, expected #{expected_unproven.inspect}"
      end
    end
    assert_empty failures, failures.join("\n  ")
  end

  def test_pilot_ready_checklist_rows_name_note_ien_from_create_fixture
    rows = parse_checklist
    create_slice = TIU_WRITE_SLICE.find { |s| s[:mapping] == :tiu_create_record }
    create_fixture = load_slice_fixture(create_slice)
    create_ien = self.class.create_ien_from_fixture(create_fixture)
    refute_nil create_ien

    pilot_ready_flow = TIU_WRITE_SLICE.select do |slice|
      slice[:evidence] == :live_capture &&
        rows[slice[:rpc]]&.dig(:status) == "pilot-ready"
    end
    refute_empty pilot_ready_flow, "expected pilot-ready live TIU rows"

    failures = []
    pilot_ready_flow.each do |slice|
      row = rows[slice[:rpc]]
      reason = row[:reason]
      unless reason.match?(NOTE_IEN_IN_REASON)
        failures << "#{slice[:rpc]} line #{row[:line]}: reason must name note IEN #{create_ien} " \
                   "(/\\bnote (IEN )?#{create_ien}\\b/), got #{reason.inspect}"
      end
      unless reason.match?(/\bnote (IEN )?#{Regexp.escape(create_ien)}\b/)
        failures << "#{slice[:rpc]} line #{row[:line]}: reason must reference create IEN #{create_ien}"
      end
    end
    assert_empty failures, failures.join("\n  ")
  end

  def test_pilot_checklist_tiu_reasons_name_seed_gap_persona_and_sign_field_gap
    rows = parse_checklist
    failures = []
    TIU_WRITE_SLICE.each do |slice|
      row = rows[slice[:rpc]]
      next failures << "#{slice[:rpc]}: missing checklist row" unless row
      next if row[:status] == "pilot-ready"

      reason = row[:reason]
      failures << "#{slice[:rpc]}: reason must mention seed gap" unless reason.match?(/seed gap/i)
      failures << "#{slice[:rpc]}: reason must name #{PILOT_PERSONA}" unless reason.include?(PILOT_PERSONA)
      next unless slice[:rpc] == "TIU SIGN RECORD"

      failures << "TIU SIGN RECORD reason must name field 20.4" unless reason.match?(/20\.4/)
      failures << "TIU SIGN RECORD reason must name PROVIDER,TEST" unless reason.include?("PROVIDER,TEST")
    end
    assert_empty failures, failures.join("\n  ")
  end

  def test_pilot_ready_tiu_fixtures_replay_through_public_api
    failures = []
    TIU_WRITE_SLICE.each do |slice|
      next unless slice[:evidence] == :live_capture

      fixture = load_slice_fixture(slice)
      entry = catalog_entry!(slice[:rpc])
      next unless expected_checklist_status(slice, fixture, entry) == "pilot-ready"

      raw = fixture.raw_return.to_s.sub(/\A\d+[\x00\x01]/, "")
      client = TiuProbeClient.new(slice[:rpc] => raw)
      RpmsRpc.reset!
      RpmsRpc.configure { |cfg| cfg.client = client }

      case slice[:mapping]
      when :tiu_create_record
        result = RpmsRpc::ProgressNote.create("4", "4", "248")
        ien = self.class.create_ien_from_fixture(fixture)
        unless result[:success] && result[:ien].to_s == ien
          failures << "#{slice[:rpc]}: create replay expected IEN #{ien}, got #{result.inspect}"
        end
      when :tiu_lock_record
        note_ien = fixture.inputs[0]
        failures << "#{slice[:rpc]}: lock replay must succeed" unless RpmsRpc::ProgressNote.lock(note_ien)
      when :tiu_unlock_record
        note_ien = fixture.inputs[0]
        failures << "#{slice[:rpc]}: unlock replay must succeed" unless RpmsRpc::ProgressNote.unlock(note_ien)
      when :tiu_set_document_text
        note_ien = fixture.inputs[0]
        update = RpmsRpc::ProgressNote.update_text(note_ien, note_text)
        failures << "#{slice[:rpc]}: update_text replay must succeed" unless update[:success]
      end
    ensure
      RpmsRpc.reset!
    end
    assert_empty failures, failures.join("\n  ")
  end
end
