# frozen_string_literal: true

require "fileutils"
require "json"
require "time"
require "yaml"

# The live-run record a release is allowed to trust (rpms-rpc#361, ADR 0010
# assertion 10). `rake test:live` writes one JSON file per persona; the
# release guard reads them back and refuses to tag unless every file is a
# green run of the single pinned build. Not loaded by the gem entry point:
# a host process never needs it.
module RpmsRpc
  module LiveSummary
    SCHEMA = 1
    REQUIRED_FIELDS = %w[schema build build_source protocol persona runs assertions failures errors skips written_at].freeze
    COUNT_FIELDS = %w[runs skips failures errors].freeze
    DEFAULT_DIR = "coverage/live"

    module_function

    # LIVE_SUMMARY_DIR when set and not blank, otherwise coverage/live.
    # Relative paths are resolved by the caller (the repo root).
    def dir(env = ENV)
      chosen = env["LIVE_SUMMARY_DIR"].to_s.strip
      chosen.empty? ? DEFAULT_DIR : chosen
    end

    # Write one persona summary. Quiet, and creates nothing, unless this is a
    # live run that actually has a broker: the guard must not be fed a file
    # from `rake test` or from a half-configured shell.
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

    # [ok, reasons]. Fail closed: a blank build, a missing directory, or any
    # file that is not a green run of `build` is a reason. An exception in
    # one file becomes a reason for that file; it does not escape.
    def check(dir:, build:)
      reasons = refusal_reasons(dir, build)
      [ reasons.empty?, reasons ]
    rescue StandardError => e
      [ false, [ "#{e.class}: #{e.message}" ] ]
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

    private_class_method :stringify_keys, :refusal_reasons, :missing_summary, :reasons_for, :count_reasons, :release_keys
  end
end
