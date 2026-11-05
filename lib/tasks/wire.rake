# frozen_string_literal: true

# Wire-shape capture pipeline (docs/WIRE_CONTRACTS.md, issue #189).
#
#   rake wire:capture CONTAINER=rpms-ydb-9.0 RELEASE=bcer-9.0-ydb
#     [RUNTIME=docker] [BROKER_PORT=9100] [RPMS_ACCESS=] [RPMS_VERIFY=] [ONLY="RPC NAME"]
#   rake wire:capture BROKER_HOST=127.0.0.1 BROKER_PORT=<port> RELEASE=bcer-9.0-ydb ...
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
namespace :wire do
  FIXTURES_DIR = ENV["WIRE_FIXTURES_DIR"] ? File.expand_path(ENV["WIRE_FIXTURES_DIR"]) : File.expand_path("../../test/fixtures/wire_captures", __dir__)

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
    cite_only = (ENV["CITE_ONLY"] || "").split(",").map(&:strip)
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
      next if only && entry.rpc != only

      if entry.write?
        # No capture keeps an existing fixture and routine-cites only when the
        # file is absent. A capture is written only as live-capture, with the
        # captured inputs rather than the catalog placeholder.
        data = write_entry_fixture_data(entry, captures, release, captured_at, acc)
        next if data.nil?
      elsif entry.live? && !cite_only.include?(entry.rpc)
        capture = captures[entry.rpc]
        next if capture.nil? # no container / not in this run: keep existing fixture

        if capture["error"]
          warn "SKIP #{entry.rpc}: #{capture["error"]} (existing fixture kept)"
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
          warn "SKIP #{entry.rpc}: broker returned an error reply (existing fixture kept)"
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
        warn "SKIP #{entry.rpc}: #{e.message} (existing fixture kept)"
        next
      end

      path = File.join(FIXTURES_DIR, "#{entry.rpc.downcase.tr(" /", "--")}.yml")
      File.write(path, fixture_header(entry, data) + YAML.dump(data))
      puts "Wrote #{path} (#{data["source"]})"
      written += 1
    end
    puts "#{written} fixture(s) written to #{FIXTURES_DIR}"
  end

  # A scratch capture against the committed fixtures (rpms-ops#975): a capture
  # is only evidence when it comes from a fresh container of the release, and a
  # drifted one must be visible BEFORE it replaces a committed fixture. Prints
  # one row per RPC and, with OUT=, writes the same as TSV (rpc, verdict,
  # committed source, captured source).
  #
  #   rake wire:compare CAPTURED=<dir written by WIRE_FIXTURES_DIR=<dir> rake wire:capture>
  #
  # The verdicts are RpmsRpc::WireCapture.compare's.
  desc "Compare a scratch wire capture (CAPTURED=<dir>) with the committed fixtures: SAME/DIFFERENT per RPC [OUT=<tsv>]"
  task :compare do
    require "rpms_rpc/wire_capture"

    captured_dir = ENV["CAPTURED"].to_s
    abort "wire:compare: set CAPTURED=<dir> (a WIRE_FIXTURES_DIR capture)" if captured_dir.empty?
    abort "wire:compare: no fixtures in #{captured_dir}" if Dir.glob(File.join(captured_dir, "*.yml")).empty?

    rows = RpmsRpc::WireCapture.compare(RpmsRpc::WireCapture::FIXTURES_DIR, captured_dir)

    width = rows.map { |r| r[0].length }.max.to_i
    puts format("%-#{width}s  %-12s  %-12s  %s", "RPC", "VERDICT", "COMMITTED", "CAPTURED")
    rows.each { |r| puts format("%-#{width}s  %-12s  %-12s  %s", *r) }
    counts = rows.group_by { |r| r[1] }.transform_values(&:size)
    puts "wire:compare: #{rows.size} RPC(s): " +
         RpmsRpc::WireCapture::COMPARE_VERDICTS.map { |v| "#{counts.fetch(v, 0)} #{v}" }.join(", ")
    File.write(ENV["OUT"], rows.map { |r| r.join("\t") }.join("\n") + "\n") if ENV["OUT"] && !ENV["OUT"].empty?
  end

  # A write entry's fixture. nil means "do not touch the files" (keep an
  # existing one, or skip a reply the API does not accept).
  def write_entry_fixture_data(entry, captures, release, captured_at, acc)
    capture = captures[entry.rpc]
    path = File.join(FIXTURES_DIR, "#{entry.rpc.downcase.tr(" /", "--")}.yml")
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
    header << if data["source"] == "live-capture"
                "# raw_return is VERBATIM from the #{data["release_tag"]} broker " \
                "(synthetic data only); do not hand-edit — re-run the capture.\n"
    elsif data["source"] == "no-data"
      # A live call that returned no rows. Never "no live call" —
      # that wording is only for routine-cite fixtures.
      "# The live call returned no data rows; do not hand-edit — re-run the capture.\n"
    else
      "# Routine-cited shape (no live call — see cite); do not hand-edit raw claims.\n"
    end
    header << "# Gated by test/rpms_rpc/wire_contract_test.rb against mapping :#{data["mapping"]}.\n"
  end
end
