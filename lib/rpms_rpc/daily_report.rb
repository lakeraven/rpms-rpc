# frozen_string_literal: true

require "json"
require "open3"
require "socket"
require "yaml"
require_relative "core"

# One command for the day's picture (rpms-rpc#365): `rake report:daily`.
#
# Pure pieces (release choice, minitest parsing, the markdown) take no I/O.
# Orchestrator runs the suites through injected collaborators. The real
# defaults — GitHub releases, a child process, the docker CLI, a CIA connect,
# a loopback port, a file — are what the rake task wires in. Sign-on codes
# are copied into one persona's `rake test:live` child and nowhere else.
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

    # BUILD= wins. Otherwise the tag of the image publishing the broker port.
    # A missing or untagged image is "unknown", never the latest release.
    def build_under_test(env:, docker:, broker_host:, broker_port:)
      explicit = env["BUILD"].to_s.strip
      return explicit unless explicit.empty?

      image_tag(docker.image_publishing_port(broker_host, broker_port)) || "unknown"
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
      lines << "# Daily RPMS-RPC report — #{input.date}"
      lines << ""
      lines << "build tested: #{input.build_tested}"
      lines << "latest release: #{input.latest_release}"
      lines << "pinned release: #{input.pinned_release}"
      lines << "rpms-rpc commit: #{input.rpms_rpc_commit}"
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
        failures.each { |name| lines << "- #{name}" }
      end
      reasons = input.suites.filter_map { |suite| suite[:reason] }
      unless reasons.empty?
        lines << ""
        reasons.each { |reason| lines << reason.to_s }
      end
      lines << ""
      lines << coverage_line(input.coverage)
      "#{lines.join("\n")}\n"
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
      issues = Array(suite[:skip_issues]).join(", ")
      issues_cell = issues.empty? ? "" : "#{issues} "
      wall = format("%.1fs", suite[:wall_seconds].to_f)
      "| #{suite[:name]} | #{count_cell(suite[:runs])} | #{count_cell(suite[:passed])} | " \
        "#{count_cell(suite[:failures])} | #{count_cell(suite[:errors])} | #{count_cell(suite[:skips])} | " \
        "#{issues_cell}| #{wall} |"
    end

    def count_cell(value)
      value.nil? ? "" : value.to_s
    end

    def coverage_line(coverage)
      if coverage[:ran]
        coverage[:headline].to_s
      else
        "rpc:coverage did not run: #{coverage[:reason]}"
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
          errored: false, runs: runs, assertions: assertions, failures: fail_count, errors: error_count,
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
    # parsed and passed. FRESH=1 starts a container and always removes it.
    # FRESH=1 DRY_RUN=1 writes the plan and stops.
    class Orchestrator
      class OutputDirectoryMissing < RpmsRpc::Error; end
      class BrokerTimeout < RpmsRpc::Error; end

      def initialize(root:, env:, releases:, runner:, docker:, broker_probe:, clock:, port_picker:, writer:,
                     rpms_diffs_dir:, pinned_release:, rpms_rpc_commit:, coverage:,
                     summary_writer: nil, plan_io: $stdout)
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
        @rpms_diffs_dir = rpms_diffs_dir
        @pinned_release = pinned_release
        @rpms_rpc_commit = rpms_rpc_commit
        @coverage = coverage
      end

      def run
        ensure_output_directory!
        @reported_on = @clock.now.utc.strftime("%Y-%m-%d")
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

      def run_fresh(latest)
        port = @port_picker.free_loopback_port
        if enabled?("DRY_RUN")
          @plan_io.write(DailyReport.redact(fresh_plan(latest, port), @env))
          return 0
        end

        container_id = nil
        begin
          container_id = @docker.run!(image: latest.fetch(:image), publish: "127.0.0.1:#{port}:#{CONTAINER_PORT}")
          unless @broker_probe.cia_connects?("127.0.0.1", port)
            raise BrokerTimeout, "CIA broker connect timed out on 127.0.0.1:#{port}"
          end

          finish(latest, host: "127.0.0.1", port: port, image: latest.fetch(:image))
        ensure
          @docker.remove!(container_id, force: true) if present_id?(container_id)
        end
      end

      def present_id?(container_id)
        !container_id.nil? && !container_id.to_s.strip.empty?
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

      def finish(latest, host:, port:, image:)
        build = resolve_build(host, port, image)
        suites = collect_suites(host, port)
        write_report(build, latest, suites)
        suites.all? { |suite| suite_ok?(suite) } ? 0 : 1
      end

      def resolve_build(host, port, image)
        if image
          explicit = @env["BUILD"].to_s.strip
          return explicit unless explicit.empty?

          return DailyReport.image_tag(image) || "unknown"
        end

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
        return false if suite[:runs].nil?

        suite[:failures].to_i.zero? && suite[:errors].to_i.zero?
      end

      def write_report(build, latest, suites)
        input = RenderInput.new(
          date: @reported_on,
          build_tested: build,
          latest_release: latest.fetch(:tag),
          pinned_release: @pinned_release,
          rpms_rpc_commit: @rpms_rpc_commit,
          suites: suites,
          coverage: @coverage
        )
        path = DailyReport.default_report_path(rpms_diffs_dir: @rpms_diffs_dir, date: @reported_on, build: build)
        body = DailyReport.redact(DailyReport.render(input), @env)
        body = "#{body.chomp}\n\nwrote #{path}\n"
        body = DailyReport.redact(body, @env)
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

    # `gh api repos/lakeraven/rpms-ops/releases`, then ReleaseChoice. The image
    # ref is the lock's `image:` for that tag when the lock pins it, otherwise
    # the same repository the lock uses, tagged with the release.
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

      private

      def fetch_releases
        stdout, stderr, status = Open3.capture3("gh", "api", "--paginate", OPS_RELEASES)
        unless status.success?
          detail = DailyReport.redact(stderr.to_s.strip.lines.first.to_s.strip, ENV)
          detail = "gh api #{OPS_RELEASES} failed" if detail.empty?
          raise ReleaseChoice::NoRelease, "no published release matches /\\Abcer-.*-ydb\\z/ (#{detail})"
        end
        parsed = JSON.parse(stdout)
        parsed.is_a?(Array) ? parsed : []
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

    # Docker CLI. `run!` accepts only a 127.0.0.1 publish spec. `remove!` uses
    # `--force` when asked and does not raise: an ensure must still run.
    class DockerCli
      class Error < RpmsRpc::Error; end

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

      def run!(image:, publish:)
        spec = publish.to_s
        raise Error, "docker publish must bind 127.0.0.1 only" unless spec.start_with?("127.0.0.1:")

        stdout, stderr, status = Open3.capture3("docker", "run", "--detach", "--publish", spec, image.to_s)
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
        Open3.capture3(*args)
        nil
      rescue StandardError
        nil
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
            return image_out.strip if ip.empty? || ip == "0.0.0.0" || ip == "::" || ip == host_s
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
