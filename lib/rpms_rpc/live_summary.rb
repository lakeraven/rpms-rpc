# frozen_string_literal: true

require "fileutils"
require "json"
require "time"
require "yaml"

# The live-run record a release is allowed to trust (rpms-rpc#361, ADR 0010
# assertion 10). `rake test:live` writes one JSON file per persona and
# protocol. CIA keeps <persona>.json, every other protocol is
# <persona>.<protocol>.json — so a green run of one line cannot replace a
# red run of another. The release guard reads them back and refuses to tag
# unless every file is a green run of the single pinned build. A pending
# marker is written before specs load, so a run that dies before the summary
# is recorded cannot leave the previous green file in place. Not loaded by
# the gem entry point: a host process never needs it.
module RpmsRpc
  module LiveSummary
    SCHEMA = 1
    REQUIRED_FIELDS = %w[schema build build_source protocol persona runs assertions failures errors skips written_at].freeze
    COUNT_FIELDS = %w[runs skips failures errors].freeze
    DEFAULT_DIR = "coverage/live"
    # The file name is the persona and the protocol, so anything else is refused.
    PERSONA_TOKEN = /\A[A-Za-z0-9_-]+\z/
    PROTOCOL_TOKEN = /\A[a-z]+\z/

    module_function

    # LIVE_SUMMARY_DIR when set and not blank, otherwise coverage/live.
    # Relative paths are resolved by the caller (the repo root).
    def dir(env = ENV)
      chosen = env["LIVE_SUMMARY_DIR"].to_s.strip
      chosen.empty? ? DEFAULT_DIR : chosen
    end

    # CIA keeps <persona>.json. Every other protocol is <persona>.<protocol>.json,
    # so one line's summary cannot overwrite another's. Persona and protocol
    # are stripped; anything but a plain token raises ArgumentError naming it.
    def path_for(dir, persona:, protocol:)
      persona = summary_token(persona, "persona", PERSONA_TOKEN)
      protocol = summary_token(protocol, "protocol", PROTOCOL_TOKEN)
      name = protocol == "cia" ? "#{persona}.json" : "#{persona}.#{protocol}.json"
      File.join(dir, name)
    end

    # Write one persona summary. Quiet, and creates nothing, unless this is a
    # live run that actually has a broker: the guard must not be fed a file
    # from `rake test` or from a half-configured shell. The file never holds
    # the host or the sign-on pair; callers must not put them in fields.
    def write(path, fields, env: ENV)
      return nil unless env["LIVE_RUN"] == "1" && !env["BROKER_HOST"].to_s.strip.empty?

      document = {
        "schema" => SCHEMA,
        "written_at" => Time.now.utc.iso8601
      }.merge(stringify_keys(fields))
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "#{JSON.generate(document)}\n")
      path
    end

    # The file `rake test:live` writes before specs load. Counts are zero and
    # pending is true, so check refuses it until a finished summary replaces
    # it. Same env gate as write.
    def mark_pending(path, persona:, protocol:, build:, build_source:, env: ENV)
      write(path, {
        "build" => build,
        "build_source" => build_source,
        "protocol" => protocol,
        "persona" => persona,
        "runs" => 0,
        "assertions" => 0,
        "failures" => 0,
        "errors" => 0,
        "skips" => 0,
        "pending" => true
      }, env: env)
    end

    # [ok, reasons]. Fail closed: a blank build, a missing directory, or any
    # file that is not a green run of `build` is a reason. An exception in
    # one file becomes a reason for that file; it does not escape.
    def check(dir:, build:)
      reasons = refusal_reasons(dir, build)
      [ reasons.empty?, reasons ]
    rescue StandardError => e
      [ false, [ "#{e.class}: #{e.message}" ] ]
    end

    # build_source values the summaries in dir name, once each, sorted.
    # The guard prints them; it does not ask the server which build answered.
    def build_sources(dir)
      return [] unless dir.is_a?(String) && File.directory?(dir)

      Dir.glob(File.join(dir, "*.json")).sort.filter_map { |path| source_of(path) }.uniq.sort
    end

    # The one release in the rpms-ops lock. Zero or several is an error:
    # the guard refuses rather than guess which build the live run was for.
    # ArgumentError, not an RpmsRpc::Error: a lock that does not name exactly
    # one build is a bad pin in the repo, not a failure a host rescues from RPMS.
    def pinned_build(lock_path)
      keys = release_keys(lock_path)
      return keys.first if keys.one?

      detail = keys.empty? ? "none" : keys.join(", ")
      raise ArgumentError, "#{lock_path} pins #{keys.size} releases (#{detail}); refusing to pick one"
    end

    # Who this live run is, for the summary file and the pending marker.
    # Shared by the rake task and Summary#report so the two cannot drift.
    # LIVE_BUILD, when set, is the runner's word ("declared"); otherwise the
    # release key in data/rpc_coverage/config.yml ("pinned"). The protocol
    # defaults to cia. Persona and protocol are stripped; path_for still
    # refuses an unsafe token.
    def run_identity(env, root:)
      declared = env["LIVE_BUILD"].to_s.strip
      build, build_source = declared.empty? ? [ coverage_release(root), "pinned" ] : [ declared, "declared" ]
      {
        persona: env["PERSONA"].to_s.strip,
        protocol: broker_protocol(env),
        build: build,
        build_source: build_source
      }
    end

    def stringify_keys(fields)
      return {} unless fields.is_a?(Hash)

      fields.to_h { |key, value| [ key.to_s, value ] }
    end

    def refusal_reasons(dir, build)
      return [ "expected build is blank" ] if build.nil? || build.to_s.strip.empty?
      return [ missing_summary(dir) ] unless dir.is_a?(String) && File.directory?(dir)

      paths = Dir.glob(File.join(dir, "*.json")).sort
      return [ missing_summary(dir) ] if paths.empty?

      paths.flat_map { |path| reasons_for(path, build) }
    end

    def missing_summary(dir)
      "no live summary in #{dir} (missing or empty): run `rake test:live` against the pinned build"
    end

    def reasons_for(path, build)
      name = File.basename(path)
      data = JSON.parse(File.read(path))
      return [ "#{name}: malformed JSON: expected an object" ] unless data.is_a?(Hash)

      reasons = []
      REQUIRED_FIELDS.each do |field|
        reasons << "#{name}: missing field #{field}" if !data.key?(field) || data[field].nil?
      end
      unless data["schema"].is_a?(Integer) && data["schema"] == SCHEMA
        reasons << "#{name}: schema must be #{SCHEMA} (got #{data['schema'].inspect})" unless data["schema"].nil?
      end
      if data.key?("build") && !data["build"].nil? && data["build"] != build
        reasons << "#{name}: build #{data['build'].inspect} is not #{build}"
      end
      counts = count_reasons(name, data, reasons)
      if counts.key?("failures") && counts.key?("errors") && counts["failures"] + counts["errors"] > 0
        reasons << "#{name}: #{counts['failures']} failures, #{counts['errors']} errors"
      end
      # Written before specs load. It stays when the run dies before the
      # summary, and it is never a green result even if the counts were.
      reasons << "#{name}: pending live run was not recorded" if data["pending"] == true
      reasons << "#{name}: no live spec ran" if counts.key?("runs") && counts.key?("skips") && counts["runs"] - counts["skips"] <= 0
      reasons
    rescue JSON::ParserError => e
      [ "#{File.basename(path)}: malformed JSON (#{e.message})" ]
    rescue SystemCallError => e
      [ "#{File.basename(path)}: #{e.message}" ]
    end

    # Non-negative integers only. A string or nil is a reason and is never
    # coerced, so "0" cannot pass for a green run.
    def count_reasons(name, data, reasons)
      COUNT_FIELDS.each_with_object({}) do |field, counts|
        value = data[field]
        if value.is_a?(Integer) && value >= 0
          counts[field] = value
        else
          reasons << "#{name}: #{field} must be a non-negative integer"
        end
      end
    end

    def release_keys(lock_path)
      data = YAML.safe_load_file(lock_path)
      releases = data.is_a?(Hash) ? data["releases"] : nil
      return [] unless releases.is_a?(Hash)

      releases.keys.map(&:to_s)
    end

    def summary_token(value, label, pattern)
      token = value.to_s.strip
      return token if token.match?(pattern)

      raise ArgumentError, "#{label} #{token.inspect} is not a safe summary name"
    end

    def broker_protocol(env)
      value = env["BROKER_PROTOCOL"].to_s.strip.downcase
      value.empty? ? "cia" : value
    end

    # The release key the live specs are pinned to. Blank when the file
    # cannot be read: check then refuses, rather than the marker guessing.
    def coverage_release(root)
      data = YAML.safe_load_file(File.join(root, "data/rpc_coverage/config.yml"))
      data.is_a?(Hash) ? data["release"].to_s.strip : ""
    rescue StandardError
      ""
    end

    def source_of(path)
      data = JSON.parse(File.read(path))
      return nil unless data.is_a?(Hash)

      source = data["build_source"]
      source.to_s unless source.nil? || source.to_s.strip.empty?
    rescue JSON::ParserError, SystemCallError
      nil
    end

    private_class_method :stringify_keys, :refusal_reasons, :missing_summary, :reasons_for,
                         :count_reasons, :release_keys, :summary_token, :broker_protocol,
                         :coverage_release, :source_of
  end
end
