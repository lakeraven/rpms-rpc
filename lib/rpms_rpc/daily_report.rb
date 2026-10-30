# frozen_string_literal: true

require "json"
require "open3"
require "securerandom"
require "socket"
require "yaml"
require_relative "core"

# One command for the day's picture (rpms-rpc#365): `rake report:daily`.
#
# Pure pieces (release choice, minitest parsing, the markdown) take no I/O.
# Orchestrator runs the suites through injected collaborators. The real
# defaults — GitHub releases, a child process, the docker CLI, a CIA connect,
# a loopback port, a file — are what Orchestrator.from_env wires in. Sign-on
# codes are copied into one persona's `rake test:live` child and nowhere else.
# That child gets LIVE_DISPOSABLE=1 under FRESH=1, and otherwise only when the
# operator set LIVE_DISPOSABLE=1. BROKER_PROTOCOL is copied there when set.
# `rake test` receives none of those.
module RpmsRpc
  module DailyReport
    # Names whose values are sign-on codes. They are omitted from every string
    # form of a child environment and scrubbed from reports, plans, and errors.
    SIGN_ON_KEYS = %w[RPMS_ACCESS RPMS_VERIFY PROV123_ACCESS PROV123_VERIFY SYS123_ACCESS SYS123_VERIFY].freeze
    LIVE_PERSONAS = %w[PROV123 SYS123].freeze
    DEVELOPMENT_PERSONAS = %w[PROV123].freeze
    IMAGE_REPOSITORY = "ghcr.io/lakeraven/rpms-ydb"
    OPS_RELEASES = "repos/lakeraven/rpms-ops/releases"
    CONTAINER_PORT = 9100
    # Hosts that mean this machine. An all-interface publish is this broker
    # only for one of these; a remote BROKER_HOST must match the publish IP.
    LOOPBACK_BROKER_HOSTS = %w[127.0.0.1 localhost ::1].freeze
    ALL_INTERFACE_BINDINGS = [ "", "0.0.0.0", "::" ].freeze
    # Process environment the child needs in order to find Ruby, Bundler, and
    # a CA bundle. Sign-on keys are not in this list, so they are not copied.
    BASELINE_EXACT = %w[PATH HOME LANG LC_ALL LC_CTYPE USER LOGNAME SHELL TMPDIR TMP TEMP TERM RUBYOPT RUBYLIB SSL_CERT_FILE SSL_CERT_DIR].freeze
    BASELINE_PREFIXES = %w[BUNDLE_ BUNDLER_ GEM_ RBENV_].freeze

    module_function

    # The release key in data/rpc_coverage/config.yml. Same fact as
    # LiveSummary.coverage_release: blank when the file cannot be read.
    def pinned_release(root:)
      data = YAML.safe_load_file(File.join(root, "data/rpc_coverage/config.yml"))
      data.is_a?(Hash) ? data["release"].to_s.strip : ""
    rescue StandardError
      ""
    end

    # BUILD= wins. Otherwise the tag of the image publishing the broker port
    # on this machine. Bindings on 0.0.0.0 or :: match only a loopback broker
    # host. A remote host, or a missing or untagged image, is "unknown" —
    # never the latest release.
    def build_under_test(env:, docker:, broker_host:, broker_port:)
      explicit = env["BUILD"].to_s.strip
      return explicit unless explicit.empty?
      return "unknown" unless loopback_broker_host?(broker_host)

      image_tag(docker.image_publishing_port(broker_host, broker_port)) || "unknown"
    end

    def loopback_broker_host?(host)
      LOOPBACK_BROKER_HOSTS.include?(host.to_s.strip.downcase)
    end

    # True when a container port binding is the broker we were asked about.
    # 0.0.0.0 and :: listen on every interface, so they count only for a
    # loopback broker host. Any other publish IP must equal that host.
    def publish_binding_matches_broker?(broker_host:, publish_host_ip:)
      ip = publish_host_ip.to_s.strip
      host = broker_host.to_s.strip
      return loopback_broker_host?(host) if ALL_INTERFACE_BINDINGS.include?(ip)

      ip == host
    end

    # Tag of a docker image ref, or nil when the ref has no tag (a digest, an
    # id, or nothing).
    def image_tag(image)
      ref = image.to_s.strip
      return nil if ref.empty?

      name = ref.split("@", 2).first
      name[/:([^:@\/]+)\z/, 1]
    end

    def rpms_diffs_dir(env, root:)
      override = env["RPMS_DIFFS_DIR"].to_s.strip
      return override unless override.empty?

      File.expand_path("../rpms-diffs", root)
    end

    def default_report_path(rpms_diffs_dir:, date:, build:)
      sanitized = build.to_s.gsub(/[^A-Za-z0-9._-]/, "_")
      File.join(rpms_diffs_dir, "rpc-coverage/daily", "#{date}-#{sanitized}.md")
    end

    def rpms_rpc_commit(root:)
      stdout, status = Open3.capture2("git", "-C", root, "rev-parse", "HEAD")
      status.success? ? stdout.strip : "unknown"
    rescue StandardError
      "unknown"
    end

    # Run `rake rpc:coverage` when the checkout can support it and keep its
    # headline. Otherwise a short reason, with no sign-on material.
    def coverage_headline(root:, env:)
      tool = File.join(root, "tools/rpc_coverage/rpc_coverage.rb")
      unless File.exist?(tool)
        return { ran: false, headline: nil, reason: "source checkout has no tools/rpc_coverage" }
      end

      diffs = rpms_diffs_dir(env, root: root)
      evidence = File.join(diffs, "rpc-coverage/live")
      unless Dir.exist?(evidence)
        return { ran: false, headline: nil, reason: "rpms-diffs checkout missing" }
      end

      child = baseline_env(env)
      child["RPMS_DIFFS_DIR"] = diffs
      stdout, stderr, status = Open3.capture3(child, "bundle", "exec", "rake", "rpc:coverage",
                                               chdir: root, unsetenv_others: true)
      text = redact("#{stdout}\n#{stderr}", env)
      if status.success?
        headline = stdout.each_line.map { |line| redact(line.strip, env) }.find { |line| line.start_with?("RPC coverage:") }
        if headline
          { ran: true, headline: headline, reason: nil }
        else
          { ran: false, headline: nil, reason: "rpc:coverage produced no headline" }
        end
      else
        { ran: false, headline: nil, reason: coverage_failure_reason(text) }
      end
    rescue StandardError => e
      { ran: false, headline: nil, reason: redact(e.message.to_s, env) }
    end

    def render(input)
      lines = []
      lines << "# Daily RPMS-RPC report — #{escape_markdown(input.date)}"
      lines << ""
      lines << "build tested: #{escape_markdown(input.build_tested)}"
      lines << "latest release: #{escape_markdown(input.latest_release)}"
      lines << "pinned release: #{escape_markdown(input.pinned_release)}"
      lines << "rpms-rpc commit: #{escape_markdown(input.rpms_rpc_commit)}"
      if input.build_tested != input.latest_release
        lines << ""
        lines << "Build tested differs from latest release."
      end
      if input.build_tested != input.pinned_release
        lines << "Build tested differs from pinned release."
      end
      lines << ""
      lines << "| suite | runs | passed | failures | errors | skips | skip issues | wall |"
      lines << "| --- | ---: | ---: | ---: | ---: | ---: | --- | ---: |"
      input.suites.each { |suite| lines << suite_row(suite) }
      failures = input.suites.flat_map { |suite| Array(suite[:first_failures]) }
      unless failures.empty?
        lines << ""
        lines << "First failures:"
        failures.each { |name| lines << "- #{escape_markdown(name)}" }
      end
      reasons = input.suites.filter_map { |suite| suite[:reason] }
      unless reasons.empty?
        lines << ""
        reasons.each { |reason| lines << escape_markdown(reason) }
      end
      lines << ""
      lines << coverage_line(input.coverage)
      "#{lines.join("\n")}\n"
    end

    # Values that arrive from releases, suites, and coverage are not markdown
    # we wrote. Neutralise the characters that would break a table, start a
    # code span, inject a tag, or split a row.
    def escape_markdown(value)
      value.to_s
           .gsub(/\r\n?|\n/, " ")
           .gsub("|", "&#124;")
           .gsub("`", "&#96;")
           .gsub("[", "&#91;")
           .gsub("]", "&#93;")
           .gsub("<", "&lt;")
    end

    # Replace sign-on values with a placeholder. String#gsub treats a String
    # pattern as literal text, so a code that contains regex metacharacters
    # is still removed whole. Longer values go first so one code that contains
    # another is removed intact.
    def redact(text, env)
      body = text.to_s
      secrets = SIGN_ON_KEYS.filter_map do |key|
        value = env[key]
        next if value.nil?

        string = value.to_s
        # A blank code is "missing", not a secret to scrub. Scrubbing it would
        # eat the spaces that markdown uses between empty table cells.
        string.strip.empty? ? nil : string
      end
      secrets.uniq.sort_by { |secret| -secret.length }.each do |secret|
        body = body.gsub(secret, "[redacted]")
      end
      body
    end

    def suite_row(suite)
      issues = Array(suite[:skip_issues]).map { |issue| escape_markdown(issue) }.join(", ")
      issues_cell = issues.empty? ? "" : "#{issues} "
      wall = format("%.1fs", suite[:wall_seconds].to_f)
      "| #{escape_markdown(suite[:name])} | #{count_cell(suite[:runs])} | #{count_cell(suite[:passed])} | " \
        "#{count_cell(suite[:failures])} | #{count_cell(suite[:errors])} | #{count_cell(suite[:skips])} | " \
        "#{issues_cell}| #{wall} |"
    end

    def count_cell(value)
      value.nil? ? "" : value.to_s
    end

    def coverage_line(coverage)
      if coverage[:ran]
        escape_markdown(coverage[:headline])
      else
        "rpc:coverage did not run: #{escape_markdown(coverage[:reason])}"
      end
    end

    def coverage_failure_reason(text)
      lines = text.to_s.lines.map(&:strip).reject(&:empty?)
      picked = lines.find { |line| line.match?(/rpc:coverage|no live evidence|FAIL:/i) } || lines.last
      reason = picked.to_s
      reason = "rpc:coverage failed" if reason.empty?
      reason.length > 240 ? "#{reason[0, 237]}..." : reason
    end

    def baseline_env(env)
      env.each_with_object({}) do |(key, value), acc|
        name = key.to_s
        next if value.nil? || value.to_s.empty?
        next if SIGN_ON_KEYS.include?(name)
        next unless BASELINE_EXACT.include?(name) || BASELINE_PREFIXES.any? { |prefix| name.start_with?(prefix) }

        acc[name] = value.to_s
      end
    end

    # Newest published bcer-*-ydb release. Drafts, prereleases, and other tags
    # are ignored. No match raises instead of guessing.
    module ReleaseChoice
      class NoRelease < RpmsRpc::Error; end

      TAG = /\Abcer-.*-ydb\z/

      def self.pick(releases)
        chosen = Array(releases).select { |release| eligible?(release) }.max_by { |release| release["published_at"].to_s }
        raise NoRelease, "no published release matches /\\Abcer-.*-ydb\\z/" if chosen.nil?

        { tag: chosen["tag_name"], published_at: chosen["published_at"] }
      end

      def self.eligible?(release)
        return false unless release.is_a?(Hash)
        return false if release["draft"] || release["prerelease"]

        release["tag_name"].to_s.match?(TAG)
      end
    end

    # Minitest's summary line and the Failure / Error / Skipped blocks above it.
    module MinitestOutput
      SUMMARY = /^\s*(\d+) runs, (\d+) assertions, (\d+) failures, (\d+) errors, (\d+) skips\s*$/
      ISSUE = /(?:[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)?#\d+/
      FAILURE_HEADERS = [ "Failure:", "Error:" ].freeze

      Summary = Data.define(
        :errored, :runs, :assertions, :failures, :errors, :skips, :passed, :first_failures, :skip_issues
      ) do
        def errored? = errored

        def ok? = !errored && failures.to_i.zero? && errors.to_i.zero?
      end

      def self.parse(stdout)
        text = stdout.to_s.gsub("\r\n", "\n")
        match = text.scan(SUMMARY).last
        if match.nil?
          return Summary.new(
            errored: true, runs: nil, assertions: nil, failures: nil, errors: nil, skips: nil,
            passed: nil, first_failures: [], skip_issues: []
          )
        end

        runs, assertions, fail_count, error_count, skips = match.map(&:to_i)
        names, issues = extract_events(text)
        Summary.new(
          errored: runs.zero?, runs: runs, assertions: assertions, failures: fail_count, errors: error_count,
          skips: skips, passed: runs - fail_count - error_count - skips,
          first_failures: names.take(5), skip_issues: issues.uniq
        )
      end

      def self.extract_events(text)
        names = []
        issues = []
        lines = text.lines.map { |line| line.delete("\r").chomp }
        index = 0
        while index < lines.length
          header = lines[index].strip
          if FAILURE_HEADERS.include?(header)
            name = lines[index + 1].to_s.strip.sub(/:\z/, "").sub(/\s+\[.*\z/, "")
            names << name unless name.empty?
            index += 2
            next
          end
          if header == "Skipped:"
            index += 1
            body = []
            while index < lines.length
              stripped = lines[index].strip
              break if stripped.empty? || FAILURE_HEADERS.include?(stripped) || stripped == "Skipped:"

              body << lines[index]
              index += 1
            end
            issues.concat(body.join("\n").scan(ISSUE))
            next
          end
          index += 1
        end
        [ names, issues ]
      end
    end

    RenderInput = Data.define(
      :date, :build_tested, :latest_release, :pinned_release, :rpms_rpc_commit, :suites, :coverage
    )

    # Runs the suites and writes the markdown. Exit 0 only when every suite
    # parsed, ran at least one test, and passed, and the build is known.
    # FRESH=1 starts a uniquely named container and removes that name
    # afterwards, including when `docker run` fails, the broker times out,
    # or the process is interrupted. A failed removal is reported and exits
    # non-zero. FRESH=1 DRY_RUN=1 writes the plan and stops, without
    # coverage, suites, or the git commit. An unresolvable release or a
    # BUILD mismatch on that dry run is written to the error stream and
    # exits non-zero. Coverage runs only once the output directory exists.
    class Orchestrator
      class OutputDirectoryMissing < RpmsRpc::Error; end
      class BrokerTimeout < RpmsRpc::Error; end
      class BuildMismatch < RpmsRpc::Error; end

      # Real collaborators. Coverage and the git commit are callables so
      # wiring and a dry run do not invoke them. Tests pass the same
      # builder and replace pieces.
      def self.from_env(root:, env:, **overrides)
        report = RpmsRpc::DailyReport
        env = persona_slots(env)
        new(
          root: root,
          env: env,
          releases: overrides.fetch(:releases) { report::GhReleases.new(root: root) },
          runner: overrides.fetch(:runner) { report::ProcessRunner.new },
          docker: overrides.fetch(:docker) { report::DockerCli.new },
          broker_probe: overrides.fetch(:broker_probe) { report::CiaBrokerProbe.new },
          clock: overrides.fetch(:clock) { report::Clock.new },
          port_picker: overrides.fetch(:port_picker) { report::LoopbackPortPicker.new },
          writer: overrides.fetch(:writer) { report::FileWriter.new },
          summary_writer: overrides.fetch(:summary_writer) { report::StdoutWriter.new },
          rpms_diffs_dir: overrides.fetch(:rpms_diffs_dir) { report.rpms_diffs_dir(env, root: root) },
          pinned_release: overrides.fetch(:pinned_release) { report.pinned_release(root: root) },
          rpms_rpc_commit: overrides.fetch(:rpms_rpc_commit) { -> { report.rpms_rpc_commit(root: root) } },
          coverage: overrides.fetch(:coverage) { -> { report.coverage_headline(root: root, env: env) } },
          plan_io: overrides.fetch(:plan_io, $stdout),
          error_io: overrides.fetch(:error_io, $stderr)
        )
      end

      # Both live personas are always part of the run. An unset sign-on
      # variable is nil, which is a missing pair, not a persona to skip.
      def self.persona_slots(env)
        filled = {}
        env.each { |key, value| filled[key.to_s] = value }
        %w[PROV123_ACCESS PROV123_VERIFY SYS123_ACCESS SYS123_VERIFY].each do |key|
          filled[key] = filled.fetch(key, nil)
        end
        filled
      end
      private_class_method :persona_slots

      def initialize(root:, env:, releases:, runner:, docker:, broker_probe:, clock:, port_picker:, writer:,
                     rpms_diffs_dir:, pinned_release:, rpms_rpc_commit:, coverage:,
                     summary_writer: nil, plan_io: $stdout, error_io: $stderr)
        @root = root
        @env = env
        @releases = releases
        @runner = runner
        @docker = docker
        @broker_probe = broker_probe
        @clock = clock
        @port_picker = port_picker
        @writer = writer
        @summary_writer = summary_writer
        @plan_io = plan_io
        @error_io = error_io
        @rpms_diffs_dir = rpms_diffs_dir
        @pinned_release = pinned_release
        @rpms_rpc_commit = rpms_rpc_commit.respond_to?(:call) ? rpms_rpc_commit : -> { rpms_rpc_commit }
        @coverage = coverage.respond_to?(:call) ? coverage : -> { coverage }
      end

      def run
        ensure_output_directory!
        @reported_on = @clock.now.utc.strftime("%Y-%m-%d")
        return fresh_dry_run if enabled?("FRESH") && enabled?("DRY_RUN")

        latest = @releases.fetch_latest_ydb
        enabled?("FRESH") ? run_fresh(latest) : finish(latest, host: @env["BROKER_HOST"], port: @env["BROKER_PORT"], image: nil)
      end

      private

      def ensure_output_directory!
        directory = File.join(@rpms_diffs_dir, "rpc-coverage", "daily")
        return if Dir.exist?(directory)

        raise OutputDirectoryMissing, "rpc-coverage/daily is missing (#{directory})"
      end

      def enabled?(key)
        @env[key].to_s.strip == "1"
      end

      # A dry run never starts a container, runs a suite, or reads the git
      # commit. An unresolvable release or a BUILD mismatch is written to
      # the error stream and the exit is non-zero.
      def fresh_dry_run
        latest = @releases.fetch_latest_ydb
        ensure_fresh_build_matches!(latest)
        port = @port_picker.free_loopback_port
        @plan_io.write(DailyReport.redact(fresh_plan(latest, port), @env))
        0
      rescue ReleaseChoice::NoRelease, BuildMismatch => e
        write_error(e.message)
        1
      end

      def run_fresh(latest)
        ensure_fresh_build_matches!(latest)
        port = @port_picker.free_loopback_port
        run_fresh_container(latest, port)
      end

      # FRESH reports the release tag that was started, including when the
      # image ref is digest-pinned and has no tag of its own. BUILD= may
      # repeat that tag; any other value aborts before the container or the
      # suites. A dry run applies the same check.
      def ensure_fresh_build_matches!(latest)
        explicit = @env["BUILD"].to_s.strip
        return if explicit.empty?

        started = started_release_tag(latest)
        return if explicit == started

        raise BuildMismatch, "BUILD=#{explicit} does not match the started release tag #{started}"
      end

      def started_release_tag(latest)
        latest.fetch(:tag).to_s
      end

      # The name is read once, before docker run, and is the only name
      # removed. ensure covers Interrupt and SignalException, which are not
      # StandardError, as well as ordinary failures.
      def run_fresh_container(latest, port)
        name = @docker.predetermined_name
        removal_failure = nil
        status = nil
        begin
          status = boot_and_finish(latest, port, name)
        ensure
          removal_failure = remove_named_container(name)
          note_removal_failure(removal_failure)
        end
        return 1 if removal_failure

        status
      end

      def boot_and_finish(latest, port, name)
        @docker.run!(
          image: latest.fetch(:image),
          publish: "127.0.0.1:#{port}:#{CONTAINER_PORT}",
          container_name: name
        )
        unless @broker_probe.cia_connects?("127.0.0.1", port)
          raise BrokerTimeout, "CIA broker connect timed out on 127.0.0.1:#{port}"
        end

        finish(latest, host: "127.0.0.1", port: port, build: started_release_tag(latest))
      end

      def remove_named_container(name)
        @docker.remove!(name, force: true)
        nil
      rescue StandardError => e
        e
      end

      def note_removal_failure(error)
        return unless error

        line = DailyReport.redact("container removal failed: #{error.message}", @env)
        write_error(line)
        body = "#{line}\n"
        @summary_writer&.write(@last_report_path, body)
        return unless @last_report_path

        @writer.write(@last_report_path, "#{@last_report_body}#{body}")
      end

      def write_error(message)
        @error_io.write("#{DailyReport.redact(message.to_s, @env)}\n")
      end

      def fresh_plan(latest, port)
        <<~PLAN
          daily report plan (dry run)
          image: #{latest[:image]}
          release: #{latest[:tag]}
          bind: 127.0.0.1:#{port}:#{CONTAINER_PORT}
          broker: 127.0.0.1:#{port}
          suites: rake test; rake test:live PERSONA=PROV123; rake test:live PERSONA=SYS123
        PLAN
      end

      def finish(latest, host:, port:, image: nil, build: nil)
        build = resolve_build(host, port, image) if build.nil?
        suites = collect_suites(host, port)
        write_report(build, latest, suites)
        # An unknown build is recorded and fails the run. Every live persona
        # is reported; a missing sign-on pair is an errored suite and also
        # fails the run.
        return 1 if build == "unknown"
        return 1 unless suites.all? { |suite| suite_ok?(suite) }

        0
      end

      def resolve_build(host, port, image)
        return DailyReport.image_tag(image) || "unknown" if image

        DailyReport.build_under_test(env: @env, docker: @docker, broker_host: host, broker_port: port)
      end

      def collect_suites(host, port)
        suites = [ run_command("rake test", %w[rake test], unit_env(host, port)) ]
        LIVE_PERSONAS.each { |persona| suites << live_suite(host, port, persona) }
        suites
      end

      def live_suite(host, port, persona)
        pair = sign_on_pair(persona)
        if pair.nil?
          return errored_suite("rake test:live (#{persona})", "missing #{persona}_ACCESS/#{persona}_VERIFY")
        end

        access, verify = pair
        run_command("rake test:live (#{persona})", %w[rake test:live], live_env(host, port, persona, access, verify))
      end

      def sign_on_pair(persona)
        access = @env["#{persona}_ACCESS"]
        verify = @env["#{persona}_VERIFY"]
        return nil if access.nil? || verify.nil?
        return nil if access.to_s.strip.empty? || verify.to_s.strip.empty?

        [ access.to_s, verify.to_s ]
      end

      def errored_suite(name, reason)
        {
          name: name, runs: nil, passed: nil, failures: nil, errors: nil, skips: nil,
          skip_issues: [], wall_seconds: 0.0, first_failures: [], errored: true, reason: reason
        }
      end

      def run_command(name, argv, env)
        started = @clock.now
        result = @runner.run(argv, env: env, chdir: @root)
        wall = @clock.now - started
        wall = 0.0 if wall.negative?
        stdout = scrub(result[:stdout])
        summary = MinitestOutput.parse(stdout)
        errored = summary.errored? || !result[:success]
        {
          name: name,
          runs: summary.runs,
          passed: summary.passed,
          failures: summary.failures,
          errors: summary.errors,
          skips: summary.skips,
          skip_issues: summary.skip_issues,
          wall_seconds: wall,
          first_failures: summary.first_failures,
          errored: errored,
          reason: command_reason(summary, result)
        }
      end

      def command_reason(summary, result)
        return "0 tests ran" if summary.runs&.zero?

        if summary.errored?
          line = DailyReport.redact(scrub(result[:stderr]), @env).strip.lines.first.to_s.strip
          return line.empty? ? "minitest summary missing" : "minitest summary missing: #{line[0, 200]}"
        end
        return "suite exited non-zero" if !result[:success] && summary.ok?

        nil
      end

      def scrub(text)
        text.to_s.dup.force_encoding(Encoding::UTF_8).scrub
      end

      def suite_ok?(suite)
        return false if suite[:errored]
        return false if suite[:runs].nil? || suite[:runs].to_i.zero?

        suite[:failures].to_i.zero? && suite[:errors].to_i.zero?
      end

      def report_coverage
        return @report_coverage if defined?(@report_coverage)

        @report_coverage = @coverage.call
      end

      def report_commit
        return @report_commit if defined?(@report_commit)

        @report_commit = @rpms_rpc_commit.call.to_s
      end

      def write_report(build, latest, suites)
        input = RenderInput.new(
          date: @reported_on,
          build_tested: build,
          latest_release: latest.fetch(:tag),
          pinned_release: @pinned_release,
          rpms_rpc_commit: report_commit,
          suites: suites,
          coverage: report_coverage
        )
        path = DailyReport.default_report_path(rpms_diffs_dir: @rpms_diffs_dir, date: @reported_on, build: build)
        body = DailyReport.redact(DailyReport.render(input), @env)
        body = "#{body.chomp}\n\nwrote #{path}\n"
        body = DailyReport.redact(body, @env)
        @last_report_path = path
        @last_report_body = body
        @writer.write(path, body)
        @summary_writer&.write(path, body)
      end

      def unit_env(host, port)
        ChildEnv.new(DailyReport.baseline_env(@env).merge(broker_pairs(host, port)))
      end

      def live_env(host, port, persona, access, verify)
        pairs = DailyReport.baseline_env(@env).merge(broker_pairs(host, port))
        pairs["PERSONA"] = persona
        pairs["RPMS_ACCESS"] = access
        pairs["RPMS_VERIFY"] = verify
        pairs["VISTA_RPC_ENV"] = "development" if DEVELOPMENT_PERSONAS.include?(persona)
        pairs["LIVE_DISPOSABLE"] = "1" if enabled?("FRESH") || @env["LIVE_DISPOSABLE"].to_s.strip == "1"
        protocol = @env["BROKER_PROTOCOL"].to_s.strip
        pairs["BROKER_PROTOCOL"] = protocol unless protocol.empty?
        ChildEnv.new(pairs)
      end

      def broker_pairs(host, port)
        pairs = {}
        host_s = host.to_s
        port_s = port.to_s
        pairs["BROKER_HOST"] = host_s unless host_s.empty?
        pairs["BROKER_PORT"] = port_s unless port_s.empty?
        pairs
      end
    end

    # Child environment whose printed form and #values omit sign-on codes.
    # #[] and #to_hash keep them, so the child process receives the codes and
    # a log, exception, or inspect of the env does not.
    class ChildEnv
      def initialize(pairs)
        @pairs = {}
        pairs.each do |key, value|
          next if value.nil?

          @pairs[key.to_s] = value.to_s
        end
      end

      def transform_keys
        mapped = {}
        @pairs.each { |key, value| mapped[yield(key).to_s] = value }
        self.class.new(mapped)
      end

      def [](key)
        @pairs[key.to_s]
      end

      def key?(key)
        @pairs.key?(key.to_s)
      end

      def values
        @pairs.map { |key, value| secret?(key) ? "[redacted]" : value }
      end

      def to_hash
        @pairs.dup
      end

      def inspect
        visible = @pairs.to_h { |key, value| [ key, secret?(key) ? "[redacted]" : value ] }
        visible.inspect
      end

      def to_s
        inspect
      end

      private

      def secret?(key)
        SIGN_ON_KEYS.include?(key)
      end
    end

    # `gh api repos/lakeraven/rpms-ops/releases`, then ReleaseChoice. When
    # that list cannot be read, NoRelease is raised with the gh error and a
    # dry run fails closed. The image ref is the lock's `image:` for that
    # tag when the lock pins it, otherwise the same repository the lock uses,
    # tagged with the release.
    class GhReleases
      def initialize(root:)
        @root = root
      end

      def fetch_latest_ydb
        picked = ReleaseChoice.pick(fetch_releases)
        {
          tag: picked[:tag],
          published_at: picked[:published_at],
          image: image_for(picked[:tag])
        }
      end

      # `gh api --paginate --slurp` yields one JSON array of page arrays.
      # A single page is the same shape with one inner array. A flat list of
      # release objects (no slurp) is left as it is.
      def self.parse_api_body(body)
        parsed = JSON.parse(body)
        return [] unless parsed.is_a?(Array)

        parsed.flatten(1)
      end

      def self.gh_api_argv
        [ "gh", "api", "--paginate", "--slurp", OPS_RELEASES ]
      end

      private

      def fetch_releases
        stdout, stderr, status = Open3.capture3(*GhReleases.gh_api_argv)
        return GhReleases.parse_api_body(stdout) if status.success?

        detail = DailyReport.redact(stderr.to_s.strip.lines.first.to_s.strip, ENV)
        detail = "gh api #{OPS_RELEASES} failed" if detail.empty?
        raise ReleaseChoice::NoRelease, "no published release matches /\\Abcer-.*-ydb\\z/ (#{detail})"
      rescue JSON::ParserError
        raise ReleaseChoice::NoRelease, "no published release matches /\\Abcer-.*-ydb\\z/ (gh api returned no JSON list)"
      end

      def image_for(tag)
        data = lock_data
        pinned = data.is_a?(Hash) ? data.dig("releases", tag, "image") : nil
        return pinned.strip if pinned.is_a?(String) && !pinned.strip.empty?

        "#{image_repository(data)}:#{tag}"
      end

      def lock_data
        path = File.join(@root, "data/fingerprints/rpms-ops.lock.yml")
        return nil unless File.file?(path)

        YAML.safe_load_file(path)
      rescue StandardError
        nil
      end

      def image_repository(data)
        releases = data.is_a?(Hash) ? data["releases"] : nil
        return IMAGE_REPOSITORY unless releases.is_a?(Hash)

        ref = releases.each_value.filter_map { |entry| entry.is_a?(Hash) ? entry["image"] : nil }.last
        return IMAGE_REPOSITORY unless ref.is_a?(String)

        base = ref.strip.sub(/@.*\z/, "")
        base = base.sub(/:[^\/:]+\z/, "") if base.include?(":")
        base.empty? ? IMAGE_REPOSITORY : base
      end
    end

    # One child, with only the env hash it was given. The hash is never printed.
    class ProcessRunner
      def run(argv, env:, chdir:)
        hash = env.respond_to?(:to_hash) ? env.to_hash : env
        stdout, stderr, status = Open3.capture3(hash, *argv, chdir: chdir, unsetenv_others: true)
        { stdout: stdout.to_s, stderr: stderr.to_s, success: status.success? }
      rescue StandardError => e
        { stdout: "", stderr: e.message.to_s, success: false }
      end
    end

    # Docker CLI. `predetermined_name` is a new name on every call: the time
    # plus a random hex token, so two runs do not remove each other's
    # containers. `run!` accepts only a 127.0.0.1 publish spec. The caller
    # reads the name before the process starts and removes that same name.
    # `remove!` raises Error when `docker rm` fails.
    class DockerCli
      class Error < RpmsRpc::Error; end

      def predetermined_name
        "rpms-rpc-daily-report-#{Time.now.utc.strftime("%Y%m%d%H%M%S")}-#{SecureRandom.hex(8)}"
      end

      def image_publishing_port(host, port)
        stdout, status = Open3.capture2("docker", "ps", "--format", "{{.ID}}")
        return nil unless status.success?

        stdout.each_line do |raw_id|
          id = raw_id.strip
          next if id.empty?

          image = image_if_publishes(id, host, port)
          return image if image
        end
        nil
      rescue StandardError
        nil
      end

      def run!(image:, publish:, container_name: predetermined_name)
        spec = publish.to_s
        raise Error, "docker publish must bind 127.0.0.1 only" unless spec.start_with?("127.0.0.1:")

        name = container_name.to_s
        stdout, stderr, status = Open3.capture3(
          "docker", "run", "--detach", "--name", name, "--publish", spec, image.to_s
        )
        id = stdout.to_s.strip
        return id if status.success? && !id.empty?

        detail = stderr.to_s.strip.lines.first.to_s.strip
        raise Error, "docker run failed#{": #{detail}" unless detail.empty?}"
      end

      def remove!(container_id, force: false)
        id = container_id.to_s.strip
        return if id.empty?

        args = [ "docker", "rm" ]
        args << "--force" if force
        args << id
        _stdout, stderr, status = Open3.capture3(*args)
        return if status.success?

        detail = stderr.to_s.strip.lines.first.to_s.strip
        raise Error, detail.empty? ? "docker rm failed" : "docker rm failed: #{detail}"
      rescue Error
        raise
      rescue StandardError => e
        raise Error, "docker rm failed: #{e.message}"
      end

      private

      def image_if_publishes(id, host, port)
        image_out, image_status = Open3.capture2("docker", "inspect", "--format", "{{.Config.Image}}", id)
        return nil unless image_status.success?

        ports_out, ports_status = Open3.capture2("docker", "inspect", "--format", "{{json .NetworkSettings.Ports}}", id)
        return nil unless ports_status.success?

        ports = JSON.parse(ports_out)
        return nil unless ports.is_a?(Hash)

        wanted = port.to_s
        host_s = host.to_s
        ports.each_value do |bindings|
          Array(bindings).each do |binding|
            next unless binding.is_a?(Hash)
            next unless binding["HostPort"].to_s == wanted

            ip = binding["HostIp"].to_s
            if DailyReport.publish_binding_matches_broker?(broker_host: host_s, publish_host_ip: ip)
              return image_out.strip
            end
          end
        end
        nil
      rescue JSON::ParserError, StandardError
        nil
      end
    end

    # True once CiaClient's connect handshake answers. Retries live here so a
    # single `cia_connects?` call is the whole wait; a false result means the
    # wait is over.
    class CiaBrokerProbe
      ATTEMPTS = 90
      INTERVAL = 2

      def cia_connects?(host, port)
        ATTEMPTS.times do |attempt|
          return true if connect_once(host, port)

          sleep INTERVAL if attempt < ATTEMPTS - 1
        end
        false
      end

      private

      def connect_once(host, port)
        require "rpms_rpc/cia_client"
        client = RpmsRpc::CiaClient.new(host: host.to_s, port: Integer(port), timeout: 5)
        client.connect(host, Integer(port))
        true
      rescue StandardError
        false
      ensure
        begin
          client&.disconnect
        rescue StandardError
          nil
        end
      end
    end

    class Clock
      def now
        Time.now
      end
    end

    class LoopbackPortPicker
      def free_loopback_port
        server = TCPServer.new("127.0.0.1", 0)
        server.addr[1]
      ensure
        server&.close
      end
    end

    class FileWriter
      def write(path, body)
        File.write(path, body)
      end
    end

    # The printed summary. The file writer is separate; this one only prints.
    class StdoutWriter
      def write(_path, body)
        $stdout.write(body)
      end
    end
  end
end
