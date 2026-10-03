# frozen_string_literal: true

require "json"
require "open3"
require "socket"
require "yaml"

# rake report:daily (rpms-rpc#365): the offline suite once and the live suite once per persona,
# against the latest YottaDB build, summarised as one markdown file.
#
# DailyReport's module functions are pure (tested in test/daily_report/); Run does the I/O.
module DailyReport
  YDB_RELEASE = /\Abcer-[A-Za-z0-9._-]+-ydb\z/
  BUILD_IN_IMAGE = /(bcer-[A-Za-z0-9.]+-\d{8}-[0-9a-f]+-ydb)/
  SUMMARY = /^(\d+) runs, (\d+) assertions, (\d+) failures, (\d+) errors, (\d+) skips$/
  PROBLEM = /^\s+\d+\) (Failure|Error|Skipped):\n([^\n]+?#[^\n]+?)(?: \[[^\]\n]*\])?:\n(.*?)(?=\n\s+\d+\) |\n\d+ runs, |\z)/m
  ISSUE_REF = /\b[a-z][\w-]*#\d+\b/

  Result = Struct.new(:runs, :failures, :errors, :skips, :failed, :skip_issues, keyword_init: true) do
    def passed = runs - failures - errors - skips
  end

  Suite = Struct.new(:name, :result, :seconds, :exit_ok, keyword_init: true) do
    # A suite that never printed its summary (a load error, a crash) has not passed.
    def ok? = exit_ok && !result.nil? && result.failures.zero? && result.errors.zero?
  end

  module_function

  # The newest published bcer-*-ydb release, from `gh release list --json tagName,publishedAt,isDraft`.
  def latest_ydb_release(rows)
    rows.reject { |r| r["isDraft"] }
        .select { |r| r["tagName"].to_s.match?(YDB_RELEASE) }
        .max_by { |r| r["publishedAt"].to_s }&.fetch("tagName")
  end

  # The release a container image was built from, read from its tag, or nil.
  def build_from_image(image_ref) = image_ref.to_s[BUILD_IN_IMAGE, 1]

  # The local image of a release for this arch: ghcr.io/lakeraven/rpms-ydb:image-<release>-<key>-<arch>
  # (rpms-ops bin/ydb_image_build_local.sh), or one tagged with the bare release name.
  def pick_local_image(refs, release, arch)
    refs.find { |r| r.include?(":image-#{release}-") && r.end_with?("-#{arch}") } ||
      refs.find { |r| r.end_with?(":#{release}") }
  end

  # The build data/rpc_coverage/config.yml pins: its registry file is named for the release.
  def pinned_build(config) = File.basename(config.fetch("registry"), ".txt")

  # Counts, failing test names and the issues skips name, from minitest output (run with -v so
  # skips carry their reasons). nil when the output has no summary line: the suite did not finish.
  def parse_minitest(output)
    summary = output.scan(SUMMARY).last or return nil
    runs, _assertions, failures, errors, skips = summary.map(&:to_i)
    problems = output.scan(PROBLEM)
    Result.new(runs: runs, failures: failures, errors: errors, skips: skips,
               failed: problems.reject { |kind, _, _| kind == "Skipped" }.map { |_, name, _| name },
               skip_issues: problems.select { |kind, _, _| kind == "Skipped" }.flat_map { |_, _, msg| msg.scan(ISSUE_REF) }.uniq.sort)
  end

  # facts: date, time, build, latest, pinned, target, commit, coverage; suites: [Suite].
  def render(facts, suites, max_failed: 10)
    lines = [ "# rpms-rpc daily live report: #{facts[:date]}", "" ]
    lines << "- Run: #{facts[:time]}"
    lines << "- Build tested: #{build_line(facts)}"
    lines << "- Pinned in data/rpc_coverage/config.yml: #{facts[:pinned] == facts[:build] ? 'the same build' : "pinned #{facts[:pinned]}, tested #{facts[:build]}"}"
    lines << "- Target: #{facts[:target]}"
    lines << "- rpms-rpc: #{facts[:commit]}"
    lines << "- #{facts[:coverage]}" if facts[:coverage]
    lines << ""
    lines << "| Suite | Tests | Passed | Failed | Errors | Skipped | Time |"
    lines << "|---|--:|--:|--:|--:|--:|--:|"
    suites.each { |s| lines << suite_row(s) }
    failed = suites.flat_map { |s| (s.result&.failed || []).map { |n| "#{s.name}: #{n}" } }
    unless failed.empty?
      lines << "" << "Failing#{" (first #{max_failed} of #{failed.size})" if failed.size > max_failed}:" << ""
      failed.first(max_failed).each { |f| lines << "- #{f}" }
    end
    lines << "" << "Result: #{suites.all?(&:ok?) ? 'PASS' : 'FAIL'}"
    lines.join("\n") + "\n"
  end

  def build_line(facts)
    return "#{facts[:build]} (the latest bcer-*-ydb release)" if facts[:build] == facts[:latest]

    "#{facts[:build]}; the latest bcer-*-ydb release is #{facts[:latest]}"
  end

  def suite_row(suite)
    time = format("%.1f s", suite.seconds)
    r = suite.result
    return "| #{suite.name} | did not finish | | | | | #{time} |" if r.nil?

    skipped = r.skip_issues.empty? ? r.skips.to_s : "#{r.skips} (#{r.skip_issues.join(', ')})"
    "| #{suite.name} | #{r.runs} | #{r.passed} | #{r.failures} | #{r.errors} | #{skipped} | #{time} |"
  end

  # The I/O: resolve builds, target a broker, run the suites, write the file. #call returns the exit code.
  class Run
    PERSONAS = %w[PROV123 SYS123].freeze
    IMAGE_REPO = "ghcr.io/lakeraven/rpms-ydb"

    def initialize(env, root)
      @env = env
      @root = root
    end

    def call
      personas = (@env["PERSONAS"] || PERSONAS.join(" ")).split
      codes = persona_codes(personas)
      out_dir = output_dir
      latest = latest_release
      fresh = @env["FRESH"] == "1"
      image = fresh ? fresh_image(latest) : nil
      return dry_run(fresh, image, latest, personas, out_dir) if @env["DRY_RUN"] == "1"

      container = nil
      host, port, build, target =
        if fresh
          container = start_container(image)
          port = published_port(container)
          wait_for_broker("127.0.0.1", port, container)
          [ "127.0.0.1", port, DailyReport.build_from_image(image), "fresh container of #{image}" ]
        else
          running_target
        end

      suites = [ run_suite("rake test", {}, "test") ]
      personas.each do |p|
        env = { "BROKER_HOST" => host, "BROKER_PORT" => port.to_s, "PERSONA" => p,
                "RPMS_ACCESS" => codes[p][0], "RPMS_VERIFY" => codes[p][1] }
        env["LIVE_DISPOSABLE"] = "1" if fresh
        suites << run_suite("test:live #{p}", env, "test:live")
      end

      now = Time.now
      facts = { date: now.strftime("%Y-%m-%d"), time: now.strftime("%Y-%m-%d %H:%M %Z"), build: build || "unknown",
                latest: latest, pinned: DailyReport.pinned_build(YAML.safe_load_file(File.join(@root, "data/rpc_coverage/config.yml"))),
                target: target, commit: commit, coverage: coverage_line }
      text = DailyReport.render(facts, suites)
      path = @env["OUT"] || File.join(out_dir, "#{facts[:date]}-#{facts[:build]}.md")
      File.write(path, text)
      puts text
      puts "written: #{path}"
      suites.all?(&:ok?) ? 0 : 1
    ensure
      stop_container(container) if container
    end

    private

    def fail!(msg) = abort("report:daily: #{msg}")

    def sh(*cmd)
      out, status = Open3.capture2e(*cmd)
      fail!("`#{cmd.join(' ')}` failed: #{out.strip}") unless status.success?
      out
    end

    def persona_codes(personas)
      missing = personas.flat_map { |p| %W[#{p}_ACCESS #{p}_VERIFY] }.select { |k| @env[k].to_s.strip.empty? }
      fail!("set #{missing.join(', ')} (each persona's sign-on pair)") unless missing.empty?
      personas.to_h { |p| [ p, [ @env["#{p}_ACCESS"], @env["#{p}_VERIFY"] ] ] }
    end

    def output_dir
      return File.dirname(File.expand_path(@env["OUT"])).tap { |d| fail!("no directory #{d} for OUT=") unless Dir.exist?(d) } if @env["OUT"]

      diffs = @env["RPMS_DIFFS_DIR"] || File.expand_path("../rpms-diffs", @root)
      dir = File.expand_path(@env["OUT_DIR"] || File.join(diffs, "rpc-coverage/daily"))
      fail!("no output directory #{dir}: create it in the rpms-diffs checkout, or set OUT_DIR= or OUT=") unless Dir.exist?(dir)
      dir
    end

    def latest_release
      rows = JSON.parse(sh("gh", "release", "list", "-R", "lakeraven/rpms-ops", "--limit", "50", "--json", "tagName,publishedAt,isDraft"))
      DailyReport.latest_ydb_release(rows) or fail!("no bcer-*-ydb release on lakeraven/rpms-ops")
    end

    # The image key of a release is not derivable from the release alone, and listing GHCR tags needs
    # a token with read:packages, so the image comes from IMAGE= or the local images.
    def fresh_image(latest)
      return @env["IMAGE"] if @env["IMAGE"]

      arch = RbConfig::CONFIG["host_cpu"].match?(/arm|aarch/) ? "arm64" : "amd64"
      refs = sh("docker", "images", IMAGE_REPO, "--format", "{{.Repository}}:{{.Tag}}").split
      DailyReport.pick_local_image(refs, latest, arch) or
        fail!("no local #{IMAGE_REPO} image of #{latest} for #{arch}: pull it (its tag is image-#{latest}-<key>-#{arch}) or set IMAGE=")
    end

    def container_name = "rpms-rpc-daily-#{Process.pid}"
    def run_command(image) = [ "docker", "run", "-d", "--rm", "--name", container_name, "-p", "127.0.0.1::9100", image ]

    def dry_run(fresh, image, latest, personas, out_dir)
      puts "latest bcer-*-ydb release: #{latest}"
      if fresh
        puts "would run:  #{run_command(image).join(' ')}"
        puts "then wait:  up to #{wait_seconds}s for the CIA broker on the published loopback port to answer"
      else
        puts "would test: #{@env['BROKER_HOST']}:#{@env['BROKER_PORT']}"
      end
      puts "suites:     rake test; #{personas.map { |p| "test:live as #{p}" }.join('; ')}"
      puts "output:     #{@env['OUT'] || File.join(out_dir, "<date>-<build>.md")}"
      puts "then:       docker rm -f #{container_name}" if fresh
      0
    end

    def start_container(image)
      sh(*run_command(image))
      container_name
    end

    def stop_container(name)
      _out, status = Open3.capture2e("docker", "rm", "-f", name)
      warn "report:daily: could not remove container #{name}; remove it by hand" unless status.success?
    end

    def published_port(name) = Integer(sh("docker", "port", name, "9100/tcp").lines.first.strip.split(":").last)

    def wait_seconds = Integer(@env["WAIT_SECONDS"] || 300)

    def wait_for_broker(host, port, container)
      require "rpms_rpc/cia_client"
      deadline = Time.now + wait_seconds
      loop do
        running = Open3.capture2e("docker", "inspect", "-f", "{{.State.Running}}", container).first.strip == "true"
        fail!("container #{container} exited before its broker answered") unless running
        begin
          client = RpmsRpc::CiaClient.new(host: host, port: port, timeout: 5)
          client.connect
          client.disconnect
          return
        rescue StandardError
          fail!("the CIA broker on #{host}:#{port} did not answer within #{wait_seconds}s (WAIT_SECONDS=)") if Time.now > deadline
          sleep 5
        end
      end
    end

    # An already-running broker. Its build: BUILD=, else the image of the local container publishing that port.
    def running_target
      host = @env["BROKER_HOST"].to_s
      port = @env["BROKER_PORT"].to_s
      fail!("set BROKER_HOST and BROKER_PORT (a running broker), or FRESH=1") if host.empty? || port.empty?
      name, image = local_container(host, port)
      build = @env["BUILD"] || DailyReport.build_from_image(image)
      target = "#{host}:#{port}#{" (container #{name}, #{image})" if name}"
      [ host, Integer(port), build, target ]
    end

    def local_container(host, port)
      return [] unless %w[127.0.0.1 localhost ::1].include?(host)

      out, status = Open3.capture2e("docker", "ps", "--filter", "publish=#{port}", "--format", "{{.Names}} {{.Image}}")
      status.success? ? out.lines.first.to_s.split : []
    end

    def run_suite(name, env, task)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      out, status = Open3.capture2e(env, "bundle", "exec", "rake", task, "TESTOPTS=-v", chdir: @root)
      seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      Suite.new(name: name, result: DailyReport.parse_minitest(out), seconds: seconds, exit_ok: status.success?)
    end

    def commit
      sha = sh("git", "-C", @root, "rev-parse", "--short", "HEAD").strip
      dirty = !sh("git", "-C", @root, "status", "--porcelain").strip.empty?
      "#{sha}#{' (with uncommitted changes)' if dirty}"
    end

    # The rpc:coverage headline, from the committed live evidence (not this run); or why it is absent.
    def coverage_line
      out, _status = Open3.capture2e("bundle", "exec", "rake", "rpc:coverage", chdir: @root)
      line = out[/^RPC coverage:.*$/]
      return "#{line} (rake rpc:coverage, from committed live evidence)" if line

      "RPC coverage: not measured: #{out.lines.map(&:strip).reject(&:empty?).last}"
    end
  end
end
