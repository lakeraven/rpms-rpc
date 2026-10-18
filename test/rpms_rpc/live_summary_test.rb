# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "fileutils"
require "tmpdir"
require "rake"
require "rpms_rpc/live_summary"

# ADR 0010 assertion 10 (offline slice): a release may be tagged only when live
# summaries on disk prove a green run against the pinned rpms-ops build.
module RpmsRpc
  class LiveSummaryTest < Minitest::Test
    REPO_ROOT = File.expand_path("../..", __dir__)
    SYNTHETIC_BUILD = "bcer-9.0-20990101-abc1234-ydb"

    def test_missing_summary_refuses
      Dir.mktmpdir do |parent|
        missing = File.join(parent, "no-such-live-summary-dir")
        _ok, reasons = LiveSummary.check(dir: missing, build: SYNTHETIC_BUILD)
        refute _ok
        assert_match(/no summary|missing|empty/i, reasons.join(" "))

        empty = File.join(parent, "empty")
        FileUtils.mkdir_p(empty)
        _ok, reasons = LiveSummary.check(dir: empty, build: SYNTHETIC_BUILD)
        refute _ok
        assert_match(/no summary|missing|empty/i, reasons.join(" "))
      end
    end

    def test_summary_for_a_different_build_refuses
      Dir.mktmpdir do |dir|
        write_summary(dir, "PERSONA_A.json", summary_fields("build" => "bcer-9.0-20990102-other000-ydb"))
        _ok, reasons = refuse_check(dir)
        assert_match(/build/i, reasons.join(" "))
      end
    end

    def test_failures_refuse
      Dir.mktmpdir do |dir|
        write_summary(dir, "PERSONA_A.json", summary_fields("failures" => 2))
        _ok, reasons = refuse_check(dir)
        assert_match(/failure/i, reasons.join(" "))
      end
    end

    def test_errors_refuse
      Dir.mktmpdir do |dir|
        write_summary(dir, "PERSONA_A.json", summary_fields("errors" => 1))
        _ok, reasons = refuse_check(dir)
        assert_match(/error/i, reasons.join(" "))
      end
    end

    def test_zero_runs_refuses
      Dir.mktmpdir do |dir|
        write_summary(dir, "PERSONA_A.json", summary_fields("runs" => 0, "skips" => 0))
        _ok, reasons = refuse_check(dir)
        assert_match(/no live spec ran|runs/i, reasons.join(" "))
      end
    end

    def test_all_skipped_refuses
      Dir.mktmpdir do |dir|
        write_summary(dir, "PERSONA_A.json", summary_fields("runs" => 5, "skips" => 5))
        _ok, reasons = refuse_check(dir)
        assert_match(/no live spec ran|runs/i, reasons.join(" "))
      end
    end

    def test_malformed_json_refuses
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "PERSONA_A.json"), "{ not valid json")
        _ok, reasons = refuse_check(dir)
        assert_match(/malformed|JSON/i, reasons.join(" "))
      end
    end

    def test_missing_field_refuses
      Dir.mktmpdir do |dir|
        fields = summary_fields
        fields.delete("persona")
        write_summary(dir, "PERSONA_A.json", fields)
        _ok, reasons = refuse_check(dir)
        assert_match(/persona/i, reasons.join(" "))
      end
    end

    def test_unknown_schema_refuses
      Dir.mktmpdir do |dir|
        write_summary(dir, "PERSONA_A.json", summary_fields("schema" => 2))
        _ok, reasons = refuse_check(dir)
        assert_match(/schema/i, reasons.join(" "))
      end
    end

    def test_single_persona_is_allowed
      Dir.mktmpdir do |dir|
        write_summary(dir, "PERSONA_A.json", summary_fields)
        ok, reasons = LiveSummary.check(dir: dir, build: SYNTHETIC_BUILD)
        assert ok, reasons.join("\n")
        assert_empty reasons

        write_summary(dir, "PERSONA_B.json", summary_fields("persona" => "PERSONA_B", "failures" => 1))
        _ok, reasons = refuse_check(dir)
        assert_match(/failure/i, reasons.join(" "))
      end
    end

    def test_valid_pair_allows
      Dir.mktmpdir do |dir|
        write_summary(dir, "PERSONA_A.json", summary_fields)
        write_summary(dir, "PERSONA_B.json", summary_fields("persona" => "PERSONA_B"))
        ok, reasons = LiveSummary.check(dir: dir, build: SYNTHETIC_BUILD)
        assert ok, reasons.join("\n")
        assert_empty reasons
      end
    end

    def test_writer_writes_nothing_without_broker_env
      Dir.mktmpdir do |parent|
        path = File.join(parent, "coverage", "live", "PERSONA_A.json")
        fields = summary_fields

        LiveSummary.write(path, fields, env: {})
        refute File.exist?(path)
        refute File.directory?(File.dirname(path))

        LiveSummary.write(path, fields, env: { "LIVE_RUN" => "1" })
        refute File.exist?(path)
        refute File.directory?(File.dirname(path))

        LiveSummary.write(path, fields, env: { "LIVE_RUN" => "1", "BROKER_HOST" => " " })
        refute File.exist?(path)
        refute File.directory?(File.dirname(path))
      end
    end

    def test_writer_round_trips_through_check
      Dir.mktmpdir do |dir|
        path = File.join(dir, "PERSONA_A.json")
        fields = summary_fields
        env = { "LIVE_RUN" => "1", "BROKER_HOST" => "127.0.0.1" }
        LiveSummary.write(path, fields, env: env)
        assert File.file?(path)

        ok, reasons = LiveSummary.check(dir: dir, build: SYNTHETIC_BUILD)
        assert ok, reasons.join("\n")
        assert_empty reasons
      end
    end

    def test_release_task_aborts_on_refusal
      original_app = Rake.application
      Dir.mktmpdir do |tmpdir|
        saved_summary_dir = ENV["LIVE_SUMMARY_DIR"]
        ENV["LIVE_SUMMARY_DIR"] = tmpdir
        begin
          Rake.application = Rake::Application.new
          Rake.application.init("rake")
          Rake::Task.define_task(:release)
          load File.join(REPO_ROOT, "lib/tasks/release_guard.rake")

          assert_includes Rake::Task["release"].prerequisites, "release:live_guard"

          out, err = capture_io do
            assert_raises(SystemExit) { Rake::Task["release:live_guard"].invoke }
          end
          assert_match(/no summary|missing|empty/i, (out + err))
        ensure
          saved_summary_dir.nil? ? ENV.delete("LIVE_SUMMARY_DIR") : ENV["LIVE_SUMMARY_DIR"] = saved_summary_dir
          Rake.application = original_app
        end
      end
    end

    private

    def summary_fields(overrides = {})
      {
        "schema" => 1,
        "build" => SYNTHETIC_BUILD,
        "build_source" => "pinned",
        "protocol" => "cia",
        "persona" => "PERSONA_A",
        "runs" => 120,
        "assertions" => 400,
        "failures" => 0,
        "errors" => 0,
        "skips" => 3,
        "written_at" => "2099-01-01T00:00:00Z"
      }.merge(overrides)
    end

    def write_summary(dir, filename, fields)
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, filename), JSON.generate(fields))
    end

    def refuse_check(dir, build: SYNTHETIC_BUILD)
      ok, reasons = LiveSummary.check(dir: dir, build: build)
      refute ok
      refute_empty reasons
      [ ok, reasons ]
    end
  end
end
