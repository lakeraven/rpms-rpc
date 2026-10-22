# frozen_string_literal: true

# Wire-shape capture pipeline (docs/WIRE_CONTRACTS.md, issue #189).
#
#   rake wire:capture CONTAINER=rpms-ydb-9.0 RELEASE=bcer-9.0-ydb
#     [RUNTIME=docker] [BROKER_PORT=9100] [RPMS_ACCESS=] [RPMS_VERIFY=] [ONLY="RPC NAME"]
#   rake wire:capture BROKER_HOST=127.0.0.1 BROKER_PORT=<port> RELEASE=bcer-9.0-ydb ...
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
# Read-only discipline: the driver calls read RPCs with synthetic inputs
# against a rung WE OWN — never a customer instance, never a write RPC
# (write RPCs are routine-cited; the catalog enforces the split).
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
    ver = ENV["RPMS_VERIFY"] || "RPMS.000"
    only = ENV["ONLY"]
    # CITE_ONLY="RPC A,RPC B": write routine-cite fixtures for these
    # live-mode entries instead of calling them (e.g. the broker is down, or
    # a capture must land before the rung is reachable). The cite comes from
    # the catalog; no raw is claimed.
    cite_only = (ENV["CITE_ONLY"] || "").split(",").map(&:strip)
    captured_at = Time.now.utc.iso8601
    root = File.expand_path("../..", __dir__)

    captures = {}
    host = ENV["BROKER_HOST"].to_s.strip
    if container.nil? && !host.empty?
      require "open3"
      require "rbconfig"
      driver = File.join(root, "bin", "wire_capture_driver.rb")
      env = { "VISTA_RPC_ENV" => "development", "RPMS_RPC_LIB" => File.join(root, "lib"),
              "BROKER_HOST" => host, "BROKER_PORT" => port, "RPMS_ACCESS" => acc,
              "RPMS_VERIFY" => ver, "ONLY" => only.to_s, "CITE_ONLY" => cite_only.join(",") }
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
    RpmsRpc::WireCapture::CATALOG.each do |entry|
      next if only && entry.rpc != only

      if entry.live? && !cite_only.include?(entry.rpc)
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
        data = fixture_data(entry, release, captured_at).merge(
          "source" => source,
          "inputs" => entry.inputs,
          "raw_return" => raw,
          "sha256" => Digest::SHA256.hexdigest(raw)
        )
      else
        data = fixture_data(entry, release, captured_at).merge("source" => "routine-cite")
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

  def fixture_data(entry, release, captured_at)
    {
      "rpc" => entry.rpc,
      "mapping" => entry.mapping.to_s,
      "kind" => entry.kind,
      "release_tag" => release,
      "captured_at" => captured_at,
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
    else
      "# Routine-cited shape (no live call — see cite); do not hand-edit raw claims.\n"
    end
    header << "# Gated by test/rpms_rpc/wire_contract_test.rb against mapping :#{data["mapping"]}.\n"
  end
end
