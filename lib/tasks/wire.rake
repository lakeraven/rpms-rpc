# frozen_string_literal: true

# Wire-shape capture pipeline (docs/WIRE_CONTRACTS.md, issue #189).
#
#   rake wire:capture CONTAINER=rpms-ydb-9.0 RELEASE=bcer-9.0-ydb
#     [RUNTIME=docker] [BROKER_PORT=9100] [RPMS_ACCESS=] [RPMS_VERIFY=] [ONLY="RPC NAME|fixture-name"]
#   rake wire:capture BROKER_HOST=127.0.0.1 BROKER_PORT=<port> RELEASE=bcer-9.0-ydb ...
#   ONLY matches an entry's RPC name or its fixture name. CITE_ONLY="a,b" matches a
#   fixture name, or an RPC name for the entry whose fixture is the RPC slug; a
#   token matching no live entry aborts before any call.
#   WRITES=1 runs the whole TIU note flow (its only read is the BEHOENCX GETVISIT
#   linkage check before create) when the broker host
#   resolves to loopback addresses, CONTAINER is unset, and RPMS_ACCESS is
#   a synthetic persona. A blank ONLY is unset. A non-blank ONLY is refused;
#   the flow is one unit:
#   WRITES=1 BROKER_HOST=127.0.0.1 BROKER_PORT=<port> \
#     RPMS_ACCESS=PROV123 rake wire:capture
#   The driver connects to the resolved loopback address, not the host name.
#   RPMS_ESIG, when set, must be 6-20 characters with no leading or trailing
#   whitespace (field 20.4 stores the exact code). It is read from the
#   environment only and is never printed.
#
# Two ways to reach the broker. With CONTAINER= the driver is staged into the
# container and run there with the container's ruby. With BROKER_HOST= and no
# CONTAINER= (host mode, rpms-ops#975) it runs on THIS machine's ruby against
# the broker over the network, as every other client does: a release image
# carries no ruby, so host mode is the one that works on a release. The sign-on
# pair reaches the host-mode driver through its environment, never its argv.
#
# `wire:capture` is the human/agent capture-side step (needs the live rung
# container — like conformance:ingest needs a broker dump); the contract
# test (test/rpms_rpc/wire_contract_test.rb) is the always-on CI gate and
# needs only the committed fixtures.
#
# Read-only discipline: a read run calls read RPCs with synthetic inputs
# against a rung WE OWN — never a customer instance. Write RPCs are
# routine-cited and are not called on that run. The write run's only read is
# the BEHOENCX GETVISIT linkage check before create. WRITES=1 writes no read fixture,
# writes only the TIU write fixtures, and refuses a non-blank ONLY, because
# the TIU flow is captured together. A blank ONLY is unset. It runs only when
# the broker host resolves to loopback addresses, CONTAINER is unset, the
# access code is a README synthetic persona, and RPMS_ESIG is unset or 6-20
# characters with no leading or trailing whitespace (field 20.4 stores the
# exact code). Any other WRITES=1 aborts before a connection. The allowed run
# is host mode on this machine's ruby, so the broker must be reachable at
# BROKER_HOST:BROKER_PORT.
# RPMS_ESIG is passed only in the driver environment, never on argv, and is
# never printed. A write fixture is stored only when the public API accepts
# the reply; otherwise an existing fixture is left in place, and a routine-cite
# is written only when no fixture file exists yet.
# wire:capture_writes is the separate scheduling-write path: it aborts unless
# LIVE_DISPOSABLE=1 and the broker is loopback, and the read-back is the proof.
namespace :wire do
  FIXTURES_DIR = ENV["WIRE_FIXTURES_DIR"] ? File.expand_path(ENV["WIRE_FIXTURES_DIR"]) : File.expand_path("../../test/fixtures/wire_captures", __dir__)
  SYNTHETIC_PERSONAS = %w[SYS123 PROV123].freeze
  LOOPBACK_HOSTS = %w[127.0.0.1 localhost ::1].freeze
  ADD_WRITE_RPC = "BSDX ADD NEW APPOINTMENT"
  # Check-in, cancel, and no-show are proven only when read_before shows the
  # effect was not already true. ADD has no read_before.
  CAUSATION_WRITE_RPCS = [
    "BSDX CHECKIN APPOINTMENT",
    "BSDX CANCEL APPOINTMENT",
    "BSDX NOSHOW"
  ].freeze
  # Names the guards and not the values. Printed only when the task refuses
  # to start, before the driver is loaded and before any socket is opened.
  WRITE_CAPTURE_REFUSAL = "wire:capture_writes: refusing to run. Write captures require " \
    "LIVE_DISPOSABLE=1, a loopback BROKER_HOST (127.0.0.1, localhost, or ::1), a " \
    "synthetic RPMS_ACCESS (SYS123 or PROV123; default SYS123), and RELEASE " \
    "(non-blank). They run only against a disposable rung we own, and they abort " \
    "before any broker connection."

  desc "Capture curated RPC wire returns from a live rung container into " \
       "test/fixtures/wire_captures/*.yml (CONTAINER=, RELEASE=; without " \
       "CONTAINER only routine-cite fixtures are rewritten)"
  task :capture do
    require "digest"
    require "fileutils"
    require "json"
    require "time"
    require "yaml"
    require "rpms_rpc/wire_capture"

    container = ENV["CONTAINER"]
    release = ENV["RELEASE"] || "bcer-9.0-ydb"
    runtime = ENV["RUNTIME"] || "docker"
    port = ENV["BROKER_PORT"] || "9100"
    acc = ENV["RPMS_ACCESS"] || "SYS123"
    # Authenticates the driver only. Never written to a fixture or a message.
    ver = ENV["RPMS_VERIFY"] || "RPMS.000"
    require_synthetic_persona!(acc)
    # Blank ONLY (nil, "", whitespace) is unset. A padded name is the stripped RPC.
    only = RpmsRpc::WireCapture.normalize_only(ENV["ONLY"])
    # CITE_ONLY="RPC A,RPC B": write routine-cite fixtures for these
    # live-mode entries instead of calling them (e.g. the broker is down, or
    # a capture must land before the rung is reachable). The cite comes from
    # the catalog; no raw is claimed.
    cite_only = (ENV["CITE_ONLY"] || "").split(",").map(&:strip).reject(&:empty?)
    captured_at = Time.now.utc.iso8601
    root = File.expand_path("../..", __dir__)

    captures = {}
    host = ENV["BROKER_HOST"].to_s.strip
    writes = ENV["WRITES"] == "1"
    # Before any socket. writes false is a read capture and is not refused.
    # ONLY and RPMS_ESIG are judged here as well as in the driver.
    refusal = RpmsRpc::WireCapture.write_refusal(
      writes: writes, host: host, container: container, access: acc,
      only: only, esig: ENV["RPMS_ESIG"]
    )
    abort "wire:capture: #{refusal}" if refusal

    # Fail closed before any container or driver run.
    unmatched = RpmsRpc::WireCapture.unmatched_cite_only_tokens(RpmsRpc::WireCapture::CATALOG.select(&:live?), cite_only)
    abort "wire:capture: CITE_ONLY names no live catalog entry: #{unmatched.map(&:inspect).join(", ")}" unless unmatched.empty?

    # Write path is host mode. write_refusal has already refused any CONTAINER.
    if writes || (container.nil? && !host.empty?)
      require "open3"
      require "rbconfig"
      driver = File.join(root, "bin", "wire_capture_driver.rb")
      env = { "VISTA_RPC_ENV" => "development", "RPMS_RPC_LIB" => File.join(root, "lib"),
              "BROKER_HOST" => host, "BROKER_PORT" => port, "RPMS_ACCESS" => acc,
              "RPMS_VERIFY" => ver, "ONLY" => only.to_s, "CITE_ONLY" => cite_only.join(",") }
      if writes
        env["WRITES"] = "1"
        # May be unset. Never interpolated into a message or an argument list.
        env["RPMS_ESIG"] = ENV["RPMS_ESIG"] if ENV.key?("RPMS_ESIG")
      end
      puts "Capturing from the broker at #{host}:#{port} with this machine's ruby (host mode)."
      json, status = Open3.capture2(env, RbConfig.ruby, driver)
      abort "wire:capture driver failed (exit #{status.exitstatus}):\n#{json}" unless status.success?
      captures = JSON.parse(json).fetch("captures")
    elsif container
      driver = File.join(root, "bin", "wire_capture_driver.rb")
      # Stage lib + driver as root (`docker cp` writes as root; chmod opens the
      # tree to a non-root exec user) — the rpms-ops evidence-script pattern.
      sh "#{runtime} exec -u root #{container} sh -lc 'rm -rf /tmp/rr /tmp/rr_driver.rb && mkdir -p /tmp/rr'"
      sh "#{runtime} cp #{root}/lib #{container}:/tmp/rr/lib"
      sh "#{runtime} cp #{driver} #{container}:/tmp/rr_driver.rb"
      sh "#{runtime} exec -u root #{container} sh -lc 'chmod -R a+rX /tmp/rr /tmp/rr_driver.rb'"

      json = `#{runtime} exec #{container} sh -lc "VISTA_RPC_ENV=development RPMS_RPC_LIB=/tmp/rr/lib BROKER_HOST=127.0.0.1 BROKER_PORT=#{port} RPMS_ACCESS=#{acc} RPMS_VERIFY=#{ver} ONLY='#{only}' CITE_ONLY='#{cite_only.join(",")}' ruby /tmp/rr_driver.rb"`
      abort "wire:capture driver failed:\n#{json}" unless $?.success?
      captures = JSON.parse(json).fetch("captures")
    else
      puts "No CONTAINER= or BROKER_HOST= given — writing routine-cite fixtures only."
    end

    FileUtils.mkdir_p(FIXTURES_DIR)
    written = 0
    # A write run iterates the TIU write catalog only, so it cannot rewrite a
    # read or routine-cite fixture. A read run still routine-cites write
    # entries, so it walks both slices. ONLY is already normalized.
    entries = if writes
      RpmsRpc::WireCapture.fixture_entries(writes: true, only: only)
    else
      RpmsRpc::WireCapture.fixture_entries(writes: true, only: nil) +
        RpmsRpc::WireCapture.fixture_entries(writes: false, only: nil)
    end
    entries.each do |entry|
      next if only && !entry.named?(only)

      if entry.write?
        # No capture keeps an existing fixture and routine-cites only when the
        # file is absent. A capture is written only as live-capture, with the
        # captured inputs rather than the catalog placeholder.
        data = write_entry_fixture_data(entry, captures, release, captured_at, acc)
        next if data.nil?
      elsif entry.live? && !RpmsRpc::WireCapture.cite_only?(entry, cite_only)
        capture = captures[entry.fixture_name]
        next if capture.nil? # no container / not in this run: keep existing fixture

        if capture["error"]
          warn "SKIP #{entry.fixture_name}: #{capture["error"]} (existing fixture kept)"
          next
        end
        raw = capture.fetch("raw")
        # Label from what came back, not from the fact that the call returned.
        # A reply with no data rows is a real observation ("no-data"), not a
        # failed capture -- five committed fixtures record exactly that. Calling
        # every successful call "live-capture" made the validator reject those
        # on the way out, and the raise aborted the whole task before later
        # entries were reached, so the task could not regenerate its own
        # no-data fixtures.
        # A broker ERROR is not an observation of an empty result: the call
        # failed, so the committed fixture is better evidence than anything
        # this run can write. Downgrading it to no-data would let a transient
        # failure erase a capture-backed contract.
        if RpmsRpc::WireCapture.error_reply?(raw)
          warn "SKIP #{entry.fixture_name}: broker returned an error reply (existing fixture kept)"
          next
        end

        source = RpmsRpc::WireCapture.data_rows(raw).empty? ? "no-data" : "live-capture"
        data = fixture_data(entry, release, captured_at, acc).merge(
          "source" => source,
          "inputs" => entry.inputs,
          "raw_return" => raw,
          "sha256" => Digest::SHA256.hexdigest(raw)
        )
      else
        data = fixture_data(entry, release, captured_at, acc).merge("source" => "routine-cite").tap { |d| d.delete("signed_on_as") }
      end

      # Round-trip through the validator so an invalid fixture can never be
      # written, only rejected here at authoring time. Rejection is per entry:
      # one unwritable fixture must not abort the run and leave every later
      # entry unprocessed.
      begin
        RpmsRpc::WireCapture::Fixture.new(data)
      rescue RpmsRpc::WireCapture::InvalidFixture => e
        warn "SKIP #{entry.fixture_name}: #{e.message} (existing fixture kept)"
        next
      end

      path = fixture_file(entry)
      File.write(path, fixture_header(entry, data) + YAML.dump(data))
      puts "Wrote #{path} (#{data["source"]})"
      written += 1
    end
    puts "#{written} fixture(s) written to #{FIXTURES_DIR}"
  end

  # A scratch capture against the committed fixtures (rpms-ops#975): a capture
  # is only evidence when it comes from a fresh container of the release, and a
  # drifted one must be visible BEFORE it replaces a committed fixture. Prints
  # one row per fixture and, with OUT=, writes the same as TSV (fixture, verdict,
  # committed source, captured source).
  #
  #   rake wire:compare CAPTURED=<dir written by WIRE_FIXTURES_DIR=<dir> rake wire:capture>
  #
  # The verdicts are RpmsRpc::WireCapture.compare's.
  desc "Compare a scratch wire capture (CAPTURED=<dir>) with the committed fixtures: SAME/DIFFERENT per fixture [OUT=<tsv>]"
  task :compare do
    require "rpms_rpc/wire_capture"

    captured_dir = ENV["CAPTURED"].to_s
    abort "wire:compare: set CAPTURED=<dir> (a WIRE_FIXTURES_DIR capture)" if captured_dir.empty?
    abort "wire:compare: no fixtures in #{captured_dir}" if Dir.glob(File.join(captured_dir, "*.yml")).empty?

    rows = RpmsRpc::WireCapture.compare(RpmsRpc::WireCapture::FIXTURES_DIR, captured_dir)

    width = rows.map { |r| r[0].length }.max.to_i
    puts format("%-#{width}s  %-12s  %-12s  %s", "FIXTURE", "VERDICT", "COMMITTED", "CAPTURED")
    rows.each { |r| puts format("%-#{width}s  %-12s  %-12s  %s", *r) }
    counts = rows.group_by { |r| r[1] }.transform_values(&:size)
    puts "wire:compare: #{rows.size} fixture(s): " +
         RpmsRpc::WireCapture::COMPARE_VERDICTS.map { |v| "#{counts.fetch(v, 0)} #{v}" }.join(", ")
    File.write(ENV["OUT"], rows.map { |r| r.join("\t") }.join("\n") + "\n") if ENV["OUT"] && !ENV["OUT"].empty?
  end

  desc "Capture scheduling writes from a disposable loopback broker into " \
       "test/fixtures/wire_captures/*.yml (LIVE_DISPOSABLE=1, loopback BROKER_HOST, RELEASE=)"
  task :capture_writes do
    capture_scheduling_writes
  end

  # fixture_path(entry), in the WIRE_FIXTURES_DIR scratch dir when one is set.
  def fixture_file(entry)
    File.join(FIXTURES_DIR, File.basename(RpmsRpc::WireCapture.fixture_path(entry)))
  end

  # A write entry's fixture. nil means "do not touch the files" (keep an
  # existing one, or skip a reply the API does not accept).
  def write_entry_fixture_data(entry, captures, release, captured_at, acc)
    capture = captures[entry.rpc] # the TIU flow keys its captures by RPC
    path = fixture_file(entry)
    unless capture.is_a?(Hash)
      return nil if File.file?(path)

      return fixture_data(entry, release, captured_at, acc).merge("source" => "routine-cite").tap { |data| data.delete("signed_on_as") }
    end

    raw = capture["raw"]
    inputs = capture["inputs"]
    source = if capture.key?("error") || !raw.is_a?(String)
      nil
    else
      RpmsRpc::WireCapture.write_capture_source(
        entry, raw,
        note_body: RpmsRpc::WireCapture::NoteWriteFlow::NOTE_TEXT,
        note_ien: inputs.is_a?(Array) ? inputs[0] : nil
      )
    end
    if source == "live-capture" && inputs.is_a?(Array)
      return fixture_data(entry, release, captured_at, acc).merge(
        "source" => "live-capture",
        "inputs" => inputs,
        "raw_return" => raw,
        "sha256" => Digest::SHA256.hexdigest(raw)
      )
    end

    # The reply can be the note. The RPC name and one caret piece are enough;
    # a read-back or a long piece is not printed.
    warn "SKIP #{entry.rpc}: write refused #{write_refused_detail(entry, raw)} (existing fixture kept)"
    nil
  end

  def write_refused_detail(entry, raw)
    return "error" unless raw.is_a?(String)

    piece = raw.sub(/\A\d+[\x00\x01]/, "").split(/\r\n|\r|\n/, 2).first.to_s.split("^", 2).first.to_s
    piece = redact_esig(piece)
    note_line = RpmsRpc::WireCapture::NoteWriteFlow::NOTE_TEXT.split(/\r\n|\r|\n/, 2).first.to_s
    if entry.rpc == "TIU GET RECORD TEXT" || piece.bytesize > 80 || (!note_line.empty? && piece.include?(note_line))
      "reply withheld"
    else
      piece
    end
  end

  # The signature code must not appear in a warning. Empty when it was not set.
  def redact_esig(text)
    secret = ENV["RPMS_ESIG"].to_s
    return text if secret.empty?

    text.gsub(secret, RpmsRpc::WireCapture::NoteWriteFlow::WITHHELD)
  end

  # Abort unless the sign-on access code is a README synthetic persona
  # (WireCapture::SYNTHETIC_PERSONAS). The supplied value is never included
  # in the message, and the verify code is never written.
  def require_synthetic_persona!(access)
    return access if RpmsRpc::WireCapture::SYNTHETIC_PERSONAS.include?(access)

    abort "wire:capture: captures must sign on as a synthetic persona"
  end

  def fixture_data(entry, release, captured_at, signed_on_as)
    {
      "rpc" => entry.rpc,
      "mapping" => entry.mapping.to_s,
      "kind" => entry.kind,
      "release_tag" => release,
      "captured_at" => captured_at,
      # README synthetic persona only (SYS123 / PROV123). The verify code is
      # never a fixture field.
      "signed_on_as" => require_synthetic_persona!(signed_on_as),
      "cite" => entry.cite,
      "note" => entry.note,
      "pieces" => entry.pieces.map do |p|
        piece = { "position" => p.position, "attributes" => p.attributes }
        piece["fileman_type"] = p.fileman_type if p.fileman_type
        piece
      end
    }.compact
  end

  def fixture_header(entry, data)
    header = +"# Wire capture: #{entry.rpc} — generated by `rake wire:capture` (issue #189).\n"
    header << fixture_provenance_line(data)
    header << "# Gated by test/rpms_rpc/wire_contract_test.rb against mapping :#{data["mapping"]}.\n"
  end

  # Middle comment of a fixture header, shared by read and write captures.
  # A no-data capture is a live call that returned no rows — that sentence
  # must say so. "no live call" is only the routine-cite wording.
  def fixture_provenance_line(data)
    case data["source"]
    when "live-capture"
      "# raw_return is VERBATIM from the #{data["release_tag"]} broker " \
        "(synthetic data only); do not hand-edit — re-run the capture.\n"
    when "no-data"
      "# The live call returned no data rows; do not hand-edit — re-run the capture.\n"
    else
      "# Routine-cited shape (no live call — see cite); do not hand-edit raw claims.\n"
    end
  end

  # Host-mode scheduling-write capture (issue #565). The guard runs before the
  # driver is loaded and before any socket: a write against anything but a
  # disposable loopback rung does not start, and RELEASE must be non-blank.
  # Credentials reach the child through its environment (the parent
  # environment is inherited); nothing secret is placed on the command line
  # or into a fixture.
  def capture_scheduling_writes
    abort WRITE_CAPTURE_REFUSAL unless disposable_write_capture?

    require "digest"
    require "fileutils"
    require "json"
    require "open3"
    require "rbconfig"
    require "time"
    require "yaml"
    require "rpms_rpc/wire_capture"

    root = File.expand_path("../..", __dir__)
    release = write_release
    captured_at = Time.now.utc.iso8601
    dir = write_fixtures_dir
    FileUtils.mkdir_p(dir)

    document = run_write_driver(root)
    captures = document["captures"]
    abort "wire:capture_writes: driver returned no captures" unless captures.is_a?(Hash)
    warn "wire:capture_writes: #{document["error"]}" if document["error"].is_a?(String) && !document["error"].empty?

    raw_setup = document["setup"]
    shared_setup = fixture_setup(raw_setup)
    written = 0
    skipped = []
    RpmsRpc::WireCapture::WRITE_CATALOG.each do |entry|
      if write_one_capture(entry, captures[entry.rpc], raw_setup, shared_setup, release, captured_at, dir)
        written += 1
      else
        skipped << entry.rpc
      end
    end
    puts "#{written} fixture(s) written to #{dir}"
    # Names the RPCs only. Capture errors are already on the skip lines; this
    # line must not repeat them, and it must not repeat environment values.
    abort "wire:capture_writes: skipped #{skipped.join(", ")} (existing fixture kept)" if skipped.any?
  end

  def disposable_write_capture?
    ENV["LIVE_DISPOSABLE"] == "1" && loopback_broker_host? && SYNTHETIC_PERSONAS.include?(setup_access) &&
      release_given?
  end

  def loopback_broker_host?
    LOOPBACK_HOSTS.include?(ENV["BROKER_HOST"].to_s.strip)
  end

  def setup_access
    access = ENV["RPMS_ACCESS"]
    access.nil? || access.empty? ? "SYS123" : access
  end

  def release_given?
    !ENV["RELEASE"].to_s.strip.empty?
  end

  # The tag stamped on every fixture this run writes. RELEASE is required;
  # a blank value aborts before the driver runs.
  def write_release
    given = ENV["RELEASE"].to_s.strip
    abort WRITE_CAPTURE_REFUSAL if given.empty?

    given
  end

  def write_fixtures_dir
    override = ENV["WIRE_FIXTURES_DIR"].to_s.strip
    return File.expand_path(override) unless override.empty?

    File.expand_path("../../test/fixtures/wire_captures", __dir__)
  end

  def run_write_driver(root)
    driver = File.join(root, "bin", "wire_capture_writes_driver.rb")
    port = ENV["BROKER_PORT"].to_s.strip
    port = "9100" if port.empty?
    env = {
      "VISTA_RPC_ENV" => "development",
      "RPMS_RPC_LIB" => File.join(root, "lib"),
      "BROKER_HOST" => ENV["BROKER_HOST"].to_s.strip,
      "BROKER_PORT" => port,
      "RPMS_ACCESS" => setup_access
    }
    puts "Capturing scheduling writes from the loopback broker (host mode)."
    json, status = Open3.capture2(env, RbConfig.ruby, driver)
    abort "wire:capture_writes driver failed (exit #{status.exitstatus}):\n#{json}" unless status.success?

    JSON.parse(json)
  rescue JSON::ParserError
    abort "wire:capture_writes driver did not return JSON"
  end

  def write_one_capture(entry, capture, setup, shared_setup, release, captured_at, dir)
    unless capture.is_a?(Hash)
      warn "SKIP #{entry.rpc}: no capture (existing fixture kept)"
      return false
    end
    if capture["error"].is_a?(String) && !capture["error"].empty?
      warn "SKIP #{entry.rpc}: #{capture["error"]} (existing fixture kept)"
      return false
    end
    unless setup_recorded?(setup)
      warn "SKIP #{entry.rpc}: setup did not record resource_ien and hospital_location_id (existing fixture kept)"
      return false
    end

    persona = capture["signed_on_as"].to_s
    unless SYNTHETIC_PERSONAS.include?(persona)
      warn "SKIP #{entry.rpc}: signed_on_as is not a synthetic persona (existing fixture kept)"
      return false
    end
    duz = session_duz_map(setup["duz"])
    unless duz&.key?(persona)
      warn "SKIP #{entry.rpc}: setup did not record session DUZ (existing fixture kept)"
      return false
    end
    unless shared_setup
      warn "SKIP #{entry.rpc}: setup did not record division and " \
           "medical_center_division_institutions (existing fixture kept)"
      return false
    end

    raw = capture["raw"]
    if raw.nil? || raw.to_s.empty?
      warn "SKIP #{entry.rpc}: no raw reply (existing fixture kept)"
      return false
    end
    if RpmsRpc::WireCapture.error_reply?(raw)
      warn "SKIP #{entry.rpc}: broker returned an error reply (existing fixture kept)"
      return false
    end

    read_back = read_back_entries(capture["read_back"])
    unless read_back
      warn "SKIP #{entry.rpc}: read_back incomplete (existing fixture kept)"
      return false
    end

    source = RpmsRpc::WireCapture.data_rows(raw).empty? ? "no-data" : "live-capture"
    data = fixture_data(entry, release, captured_at, persona).merge(
      "source" => source,
      "inputs" => capture["inputs"],
      "raw_return" => raw,
      "sha256" => Digest::SHA256.hexdigest(raw),
      "write" => true,
      "api_call" => capture["api_call"],
      "setup" => shared_setup,
      "read_back" => read_back
    )
    return false unless attach_read_before(entry, capture, data)
    return false unless attach_persona_probe(entry, capture, data)

    begin
      RpmsRpc::WireCapture::Fixture.new(data)
    rescue RpmsRpc::WireCapture::InvalidFixture => e
      warn "SKIP #{entry.rpc}: #{e.message} (existing fixture kept)"
      return false
    end

    path = File.join(dir, "#{entry.fixture_name}.yml")
    File.write(path, write_fixture_header(entry, data) + YAML.dump(data))
    puts "Wrote #{path} (#{data["source"]})"
    true
  end

  def setup_recorded?(setup)
    setup.is_a?(Hash) && !setup["resource_ien"].nil? && !setup["resource_ien"].to_s.empty? &&
      !setup["hospital_location_id"].nil? && !setup["hospital_location_id"].to_s.empty?
  end

  # One setup map for every fixture this run writes, including each persona's
  # division institution IEN and the institutions #40.8 points at. A run that
  # did not record those writes nothing.
  def fixture_setup(setup)
    return nil unless setup_recorded?(setup)

    duz = session_duz_map(setup["duz"])
    division = division_map(setup["division"])
    institutions = institution_list(setup["medical_center_division_institutions"])
    return nil unless duz && division && institutions

    {
      "resource_ien" => setup["resource_ien"],
      "hospital_location_id" => setup["hospital_location_id"],
      "duz" => duz,
      "division" => division,
      "medical_center_division_institutions" => institutions,
      "notes" => setup["notes"]
    }.compact
  end

  # Synthetic persona to the division institution IEN bound at sign-on.
  # Both personas are required. A non-synthetic key or a non-integer value
  # rejects the whole map.
  def division_map(division)
    return nil unless division.is_a?(Hash)

    mapped = {}
    division.each do |persona, value|
      key = persona.to_s
      return nil unless SYNTHETIC_PERSONAS.include?(key) && value.is_a?(Integer) && value.positive?

      mapped[key] = value
    end
    return nil unless SYNTHETIC_PERSONAS.all? { |persona| mapped.key?(persona) }

    mapped
  end

  # Sorted unique positive institution IENs from MEDICAL CENTER DIVISION (#40.8).
  def institution_list(values)
    return nil unless values.is_a?(Array)

    numbers = values.map do |value|
      return nil unless value.is_a?(Integer) && value.positive?

      value
    end
    numbers = numbers.uniq.sort
    return nil if numbers.empty?

    numbers
  end

  # Persona actually signed on as, to a positive integer DUZ. A non-synthetic
  # key or a non-integer value rejects the whole map.
  def session_duz_map(duz)
    return nil unless duz.is_a?(Hash) && !duz.empty?

    mapped = {}
    duz.each do |persona, value|
      key = persona.to_s
      return nil unless SYNTHETIC_PERSONAS.include?(key) && value.is_a?(Integer) && value.positive?

      mapped[key] = value
    end
    mapped
  end

  # Same entry shape as read_back. Required for check-in, cancel, and no-show.
  def attach_read_before(entry, capture, data)
    rows = capture["read_before"]
    if rows.nil?
      return true unless CAUSATION_WRITE_RPCS.include?(entry.rpc)

      warn "SKIP #{entry.rpc}: read_before missing (existing fixture kept)"
      return false
    end

    sealed = read_back_entries(rows)
    unless sealed
      warn "SKIP #{entry.rpc}: read_before incomplete (existing fixture kept)"
      return false
    end
    data["read_before"] = sealed
    true
  end

  def read_back_entries(rows)
    return nil unless rows.is_a?(Array) && !rows.empty?
    return nil if rows.any? { |row| !row.is_a?(Hash) || row["raw"].nil? || !row["inputs"].is_a?(Hash) }

    rows.map do |row|
      raw = row["raw"]
      {
        "rpc" => row["rpc"],
        "inputs" => row["inputs"],
        "raw_return" => raw,
        "sha256" => Digest::SHA256.hexdigest(raw)
      }
    end
  end

  # The ADD fixture carries PROV123's refused booking. The other three writes
  # do not. A missing or non-synthetic probe keeps the previous ADD fixture.
  def attach_persona_probe(entry, capture, data)
    return true unless entry.rpc == ADD_WRITE_RPC

    probe = capture["persona_probe"]
    unless probe.is_a?(Hash) && !probe["raw"].to_s.empty? && SYNTHETIC_PERSONAS.include?(probe["signed_on_as"].to_s)
      warn "SKIP #{entry.rpc}: persona_probe missing or not a synthetic persona (existing fixture kept)"
      return false
    end

    raw = probe["raw"]
    data["persona_probe"] = {
      "signed_on_as" => probe["signed_on_as"],
      "inputs" => probe["inputs"],
      "raw_return" => raw,
      "sha256" => Digest::SHA256.hexdigest(raw)
    }
    true
  end

  def write_fixture_header(entry, data)
    header = +"# Wire capture: #{entry.rpc} — generated by `rake wire:capture_writes` (issue #565).\n"
    header << fixture_provenance_line(data)
    header << "# Gated by the wire contract (test/rpms_rpc/wire_contract_test.rb) and " \
              "test/rpms_rpc/pilot_scheduling_writes_test.rb against mapping :#{data["mapping"]}.\n"
  end
end
