# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "fileutils"
require "securerandom"
require "tmpdir"
require "rake"
require "rpms_rpc/live_summary"

# ADR 0010 assertion 10 (offline slice): a release may be tagged only when live
# summaries on disk prove a green run against the pinned rpms-ops build.
module RpmsRpc
  class LiveSummaryTest < Minitest::Test
    REPO_ROOT = File.expand_path("../..", __dir__)
    SYNTHETIC_BUILD = "bcer-9.0-20990101-abc1234-ydb"
    SYNTHETIC_SOURCE = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    def test_missing_summary_refuses
      Dir.mktmpdir do |parent|
        missing = File.join(parent, "no-such-live-summary-dir")
        _ok, reasons = LiveSummary.check(dir: missing, build: SYNTHETIC_BUILD, source: SYNTHETIC_SOURCE)
        refute _ok
        assert_match(/no summary|missing|empty/i, reasons.join(" "))

        empty = File.join(parent, "empty")
        FileUtils.mkdir_p(empty)
        _ok, reasons = LiveSummary.check(dir: empty, build: SYNTHETIC_BUILD, source: SYNTHETIC_SOURCE)
        refute _ok
        assert_match(/no summary|missing|empty/i, reasons.join(" "))
      end
    end

    def test_summary_for_a_different_build_refuses
      Dir.mktmpdir do |dir|
        write_summary(dir, "PERSONA_A.json", summary_fields("build" => "bcer-9.0-20990102-other000-ydb"))
        _ok, reasons = refuse_check(dir)
        assert_match(/build/i, reasons.join(" "))
        # After a pin bump, a persona not re-run keeps the old build; say how out.
        assert_match(/re-run `rake test:live` for it, or delete the file/, reasons.join(" "))
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
        write_summary(dir, "PERSONA_A.json", summary_fields("schema" => 3))
        _ok, reasons = refuse_check(dir)
        assert_match(/schema/i, reasons.join(" "))
      end
    end

    # rpms-rpc#441: a summary from before source identity says how to replace it.
    def test_a_summary_without_source_identity_refuses_and_says_rerun
      Dir.mktmpdir do |dir|
        write_summary(dir, "PERSONA_A.json", summary_fields("schema" => 1).except("source"))
        _ok, reasons = refuse_check(dir)
        assert_match(/schema must be 2 \(got 1\); re-run `rake test:live`/, reasons.join(" "))
        assert_match(/missing field source/, reasons.join(" "))
      end
    end

    # rpms-rpc#441: green evidence for revision A cannot release revision B on the same build.
    def test_green_evidence_for_another_source_refuses_on_the_same_build
      Dir.mktmpdir do |dir|
        revision_a = "sha256:#{'a' * 64}"
        revision_b = "sha256:#{'b' * 64}"
        write_summary(dir, "PERSONA_A.json", summary_fields("source" => revision_a))

        assert LiveSummary.check(dir: dir, build: SYNTHETIC_BUILD, source: revision_a).first
        _ok, reasons = refuse_check(dir, source: revision_b)
        assert_match(/tested source #{revision_a} is not the source being released \(#{revision_b}\)/, reasons.join(" "))
      end
    end

    def test_a_blank_expected_source_refuses
      Dir.mktmpdir do |dir|
        write_summary(dir, "PERSONA_A.json", summary_fields)
        _ok, reasons = refuse_check(dir, source: " ")
        assert_equal [ "expected source is blank" ], reasons
      end
    end

    # The fingerprint is the files the gemspec ships, read from the working tree.
    def test_source_fingerprint_follows_the_shipped_files_only
      Dir.mktmpdir do |root|
        File.write(File.join(root, "probe.gemspec"), <<~SPEC)
          Gem::Specification.new do |spec|
            spec.name = "probe"
            spec.version = "0.0.1"
            spec.summary = "probe"
            spec.authors = [ "probe" ]
            spec.files = Dir.chdir(__dir__) { Dir["lib/**/*"] }
          end
        SPEC
        FileUtils.mkdir_p(File.join(root, "lib"))
        File.write(File.join(root, "lib/probe.rb"), "A = 1\n")
        File.write(File.join(root, "CHANGELOG.md"), "one\n")
        first = LiveSummary.source_fingerprint(root)
        assert_match(/\Asha256:[0-9a-f]{64}\z/, first)

        File.write(File.join(root, "CHANGELOG.md"), "two: the release section quotes the live summary\n")
        assert_equal first, LiveSummary.source_fingerprint(root), "CHANGELOG.md is not shipped"

        File.write(File.join(root, "lib/probe.rb"), "A = 2\n")
        changed = LiveSummary.source_fingerprint(root)
        refute_equal first, changed, "an uncommitted edit to a shipped file counts"

        File.write(File.join(root, "lib/added.rb"), "B = 1\n")
        refute_equal changed, LiveSummary.source_fingerprint(root), "a shipped file added since counts"
      end
    end

    def test_source_fingerprint_without_a_gemspec_raises
      Dir.mktmpdir do |root|
        error = assert_raises(ArgumentError) { LiveSummary.source_fingerprint(root) }
        assert_match(/no gemspec/, error.message)
      end
    end

    def test_single_persona_is_allowed
      Dir.mktmpdir do |dir|
        write_summary(dir, "PERSONA_A.json", summary_fields)
        ok, reasons = LiveSummary.check(dir: dir, build: SYNTHETIC_BUILD, source: SYNTHETIC_SOURCE)
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
        ok, reasons = LiveSummary.check(dir: dir, build: SYNTHETIC_BUILD, source: SYNTHETIC_SOURCE)
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

        ok, reasons = LiveSummary.check(dir: dir, build: SYNTHETIC_BUILD, source: SYNTHETIC_SOURCE)
        assert ok, reasons.join("\n")
        assert_empty reasons
      end
    end

    def test_cia_and_xwb_runs_for_one_persona_do_not_share_a_file
      Dir.mktmpdir do |dir|
        cia = LiveSummary.path_for(dir, persona: "PERSONA_A", protocol: "cia")
        xwb = LiveSummary.path_for(dir, persona: "PERSONA_A", protocol: "xwb")
        refute_equal cia, xwb
      end
    end

    def test_red_cia_and_green_xwb_for_one_persona_refuses
      Dir.mktmpdir do |dir|
        env = { "LIVE_RUN" => "1", "BROKER_HOST" => "127.0.0.1" }
        cia_path = LiveSummary.path_for(dir, persona: "PERSONA_A", protocol: "cia")
        xwb_path = LiveSummary.path_for(dir, persona: "PERSONA_A", protocol: "xwb")
        LiveSummary.write(cia_path, summary_fields("protocol" => "cia", "failures" => 2), env: env)
        LiveSummary.write(xwb_path, summary_fields("protocol" => "xwb"), env: env)
        _ok, reasons = refuse_check(dir)
        assert_match(/failure/i, reasons.join(" "))
      end
    end

    def test_path_for_refuses_an_unsafe_persona
      assert_raises(ArgumentError) do
        LiveSummary.path_for("/tmp", persona: "../x", protocol: "cia")
      end
    end

    def test_pending_marker_refuses
      Dir.mktmpdir do |dir|
        path = LiveSummary.path_for(dir, persona: "PERSONA_A", protocol: "cia")
        mark_pending_at(path)
        _ok, reasons = refuse_check(dir)
        assert_match(/pending|no live spec ran/i, reasons.join(" "))
      end
    end

    def test_pending_marker_replaces_a_stale_green_file
      Dir.mktmpdir do |dir|
        path = LiveSummary.path_for(dir, persona: "PERSONA_A", protocol: "cia")
        write_summary(dir, File.basename(path), summary_fields)
        mark_pending_at(path)
        _ok, reasons = refuse_check(dir)
        assert_match(/pending|no live spec ran/i, reasons.join(" "))
      end
    end

    def test_pending_task_stamps_a_run_id
      original_app = Rake.application
      Dir.mktmpdir do |tmpdir|
        saved_live_run = ENV["LIVE_RUN"]
        saved_broker_host = ENV["BROKER_HOST"]
        saved_persona = ENV["PERSONA"]
        saved_summary_dir = ENV["LIVE_SUMMARY_DIR"]
        saved_live_build = ENV["LIVE_BUILD"]
        saved_live_run_id = ENV["LIVE_RUN_ID"]
        begin
          Rake.application = Rake::Application.new
          Rake.application.init("rake")
          Rake::Task.define_task("test:live_settings")
          Rake::Task.define_task("test:live" => [ "test:live_settings" ])
          load File.join(REPO_ROOT, "lib/tasks/release_guard.rake")

          ENV["LIVE_RUN"] = "1"
          ENV["BROKER_HOST"] = "127.0.0.1"
          ENV["PERSONA"] = "PERSONA_A"
          ENV["LIVE_SUMMARY_DIR"] = tmpdir
          ENV["LIVE_BUILD"] = SYNTHETIC_BUILD
          ENV.delete("LIVE_RUN_ID")
          Rake::Task["test:live_summary_pending"].invoke

          pending_path = LiveSummary.path_for(tmpdir, persona: "PERSONA_A", protocol: "cia")
          data = JSON.parse(File.read(pending_path))
          refute data["run_id"].to_s.strip.empty?
          assert_match(/\A[0-9a-f]+\z/, data["run_id"])
          assert_equal data["run_id"], ENV["LIVE_RUN_ID"]
        ensure
          saved_live_run.nil? ? ENV.delete("LIVE_RUN") : ENV["LIVE_RUN"] = saved_live_run
          saved_broker_host.nil? ? ENV.delete("BROKER_HOST") : ENV["BROKER_HOST"] = saved_broker_host
          saved_persona.nil? ? ENV.delete("PERSONA") : ENV["PERSONA"] = saved_persona
          saved_summary_dir.nil? ? ENV.delete("LIVE_SUMMARY_DIR") : ENV["LIVE_SUMMARY_DIR"] = saved_summary_dir
          saved_live_build.nil? ? ENV.delete("LIVE_BUILD") : ENV["LIVE_BUILD"] = saved_live_build
          saved_live_run_id.nil? ? ENV.delete("LIVE_RUN_ID") : ENV["LIVE_RUN_ID"] = saved_live_run_id
          Rake.application = original_app
        end
      end
    end

    def test_pending_task_initializes_settings_when_invoked_first
      with_parallel_live_tasks do |path, build|
        # Request the marker before settings, a prerequisite order -m may
        # choose. No sleeps or scheduler luck: the marker must initialize
        # its own dependency even when LIVE_RUN was not exported.
        Rake::Task["test:live_summary_pending"].invoke

        assert_equal "1", ENV["LIVE_RUN"]
        assert LiveSummary.pending_for?(path, ENV["LIVE_RUN_ID"]),
               "the marker must replace the old green summary before specs load"
        ok, reasons = LiveSummary.check(dir: File.dirname(path), build: build, source: repo_source)
        refute ok
        assert_match(/pending/, reasons.join(" "))
      end
    end

    def test_parallel_live_failure_blocks_release_instead_of_reusing_old_green
      with_parallel_live_tasks do |path, _build|
        Rake::Task["test:live"].enhance { raise "synthetic live process failed before reporting" }

        error = assert_raises(RuntimeError) { Rake::Task["test:live"].invoke }
        assert_equal "synthetic live process failed before reporting", error.message
        assert LiveSummary.pending_for?(path, ENV["LIVE_RUN_ID"])

        _out, err = capture_io do
          assert_raises(SystemExit) { Rake::Task["release"].invoke }
        end
        assert_match(/pending live run was not recorded/, err)
      end
    end

    def test_live_task_marks_pending_before_specs_load
      original_app = Rake.application
      Dir.mktmpdir do |tmpdir|
        saved_live_run = ENV["LIVE_RUN"]
        saved_broker_host = ENV["BROKER_HOST"]
        saved_persona = ENV["PERSONA"]
        saved_summary_dir = ENV["LIVE_SUMMARY_DIR"]
        saved_live_build = ENV["LIVE_BUILD"]
        begin
          Rake.application = Rake::Application.new
          Rake.application.init("rake")
          Rake::Task.define_task("test:live_settings")
          Rake::Task.define_task("test:live" => [ "test:live_settings" ])
          load File.join(REPO_ROOT, "lib/tasks/release_guard.rake")

          # The marker leads the live action, and settings lead the marker:
          # a dependency, so it holds under rake -m where list order does not.
          assert_includes Rake::Task["test:live"].prerequisites, "test:live_summary_pending"
          assert_includes Rake::Task["test:live_summary_pending"].prerequisites, "test:live_settings"

          ENV["LIVE_RUN"] = "1"
          ENV["BROKER_HOST"] = "127.0.0.1"
          ENV["PERSONA"] = "PERSONA_A"
          ENV["LIVE_SUMMARY_DIR"] = tmpdir
          ENV["LIVE_BUILD"] = SYNTHETIC_BUILD
          Rake::Task["test:live_summary_pending"].invoke

          pending_path = LiveSummary.path_for(tmpdir, persona: "PERSONA_A", protocol: "cia")
          assert File.file?(pending_path)
          _ok, reasons = refuse_check(tmpdir)
          assert_match(/pending|no live spec ran/i, reasons.join(" "))
        ensure
          saved_live_run.nil? ? ENV.delete("LIVE_RUN") : ENV["LIVE_RUN"] = saved_live_run
          saved_broker_host.nil? ? ENV.delete("BROKER_HOST") : ENV["BROKER_HOST"] = saved_broker_host
          saved_persona.nil? ? ENV.delete("PERSONA") : ENV["PERSONA"] = saved_persona
          saved_summary_dir.nil? ? ENV.delete("LIVE_SUMMARY_DIR") : ENV["LIVE_SUMMARY_DIR"] = saved_summary_dir
          saved_live_build.nil? ? ENV.delete("LIVE_BUILD") : ENV["LIVE_BUILD"] = saved_live_build
          Rake.application = original_app
        end
      end
    end

    def test_pending_task_aborts_on_an_unsafe_persona
      original_app = Rake.application
      Dir.mktmpdir do |tmpdir|
        saved_live_run = ENV["LIVE_RUN"]
        saved_broker_host = ENV["BROKER_HOST"]
        saved_persona = ENV["PERSONA"]
        saved_summary_dir = ENV["LIVE_SUMMARY_DIR"]
        begin
          Rake.application = Rake::Application.new
          Rake.application.init("rake")
          Rake::Task.define_task("test:live_settings")
          Rake::Task.define_task("test:live" => [ "test:live_settings" ])
          load File.join(REPO_ROOT, "lib/tasks/release_guard.rake")

          ENV["LIVE_RUN"] = "1"
          ENV["BROKER_HOST"] = "127.0.0.1"
          ENV["PERSONA"] = "../x"
          ENV["LIVE_SUMMARY_DIR"] = tmpdir
          assert Rake::Task.task_defined?("test:live_summary_pending"), "missing rake task test:live_summary_pending"
          assert_raises(SystemExit) { Rake::Task["test:live_summary_pending"].invoke }
        ensure
          saved_live_run.nil? ? ENV.delete("LIVE_RUN") : ENV["LIVE_RUN"] = saved_live_run
          saved_broker_host.nil? ? ENV.delete("BROKER_HOST") : ENV["BROKER_HOST"] = saved_broker_host
          saved_persona.nil? ? ENV.delete("PERSONA") : ENV["PERSONA"] = saved_persona
          saved_summary_dir.nil? ? ENV.delete("LIVE_SUMMARY_DIR") : ENV["LIVE_SUMMARY_DIR"] = saved_summary_dir
          Rake.application = original_app
        end
      end
    end

    def test_pending_task_aborts_when_the_marker_is_not_written
      with_parallel_live_tasks do |path, _build|
        # The writer stays quiet without a broker host. The task must not then
        # run the specs with the old green summary still in place.
        ENV["BROKER_HOST"] = " "
        _out, err = capture_io do
          assert_raises(SystemExit) { Rake::Task["test:live_summary_pending"].invoke }
        end
        assert_match(/no pending marker/, err)
        refute LiveSummary.pending_for?(path, ENV["LIVE_RUN_ID"])
      end
    end

    def test_release_guard_leads_bundler_release_and_guards_its_push_tasks
      original_app = Rake.application
      begin
        Rake.application = Rake::Application.new
        Rake.application.init("rake")
        Dir.chdir(REPO_ROOT) do
          require "bundler/gem_helper"
          Bundler::GemHelper.install_tasks
          load File.join(REPO_ROOT, "lib/tasks/release_guard.rake")
        end
        assert_equal "release:live_guard", Rake::Task["release"].prerequisites.first
        assert_includes Rake::Task["release:source_control_push"].prerequisites, "release:live_guard"
        assert_includes Rake::Task["release:rubygem_push"].prerequisites, "release:live_guard"
      ensure
        Rake.application = original_app
      end
    end

    def test_release_guard_ok_names_the_build_source
      original_app = Rake.application
      lock_path = File.join(REPO_ROOT, "data/fingerprints/rpms-ops.lock.yml")
      build = LiveSummary.pinned_build(lock_path)
      Dir.mktmpdir do |tmpdir|
        saved_summary_dir = ENV["LIVE_SUMMARY_DIR"]
        ENV["LIVE_SUMMARY_DIR"] = tmpdir
        begin
          path = File.join(tmpdir, "PERSONA_A.json")
          write_summary(tmpdir, "PERSONA_A.json", summary_fields("build" => build, "build_source" => "pinned", "source" => repo_source))

          Rake.application = Rake::Application.new
          Rake.application.init("rake")
          load File.join(REPO_ROOT, "lib/tasks/release_guard.rake")

          out, err = capture_io { Rake::Task["release:live_guard"].invoke }
          assert_match(/OK #{Regexp.escape(build)}/, out + err)
          # A run with skips passes, so the OK names how many were skipped.
          assert_match(/PERSONA_A\.json: 117 passed, 3 skipped \(pinned\)/, out + err)
        ensure
          saved_summary_dir.nil? ? ENV.delete("LIVE_SUMMARY_DIR") : ENV["LIVE_SUMMARY_DIR"] = saved_summary_dir
          Rake.application = original_app
        end
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

    # PR #440 review: run A checks its marker, run B marks pending, A writes over B's marker. With the
    # check and the write one step under the summary lock, B's mark_pending waits until A has written,
    # so B's marker is the one left on disk, and the guard refuses until B reports.
    def test_a_competing_mark_pending_waits_for_the_replace_and_its_marker_survives
      Dir.mktmpdir do |dir|
        path = File.join(dir, "PERSONA_A.json")
        env = { "LIVE_RUN" => "1", "BROKER_HOST" => "127.0.0.1" }
        mark_pending_at(path, run_id: "run-a", env: env)
        b = nil
        result = LiveSummary.replace_pending(path, "run-a", SYNTHETIC_SOURCE, summary_fields, env: env,
                                             before_write: lambda {
                                               b = Thread.new { mark_pending_at(path, run_id: "run-b", env: env) }
                                               refute b.join(0.3), "run B marked pending inside run A's check-and-write"
                                             })
        assert_equal :written, result
        b.join(5)
        refute b.alive?, "run B never marked pending after run A released the lock"
        data = JSON.parse(File.read(path))
        assert_equal true, data["pending"], "run A's summary overwrote run B's pending marker"
        assert_equal "run-b", data["run_id"]
      end
    end

    def test_replace_refuses_when_another_run_marked_pending_first
      Dir.mktmpdir do |dir|
        path = File.join(dir, "PERSONA_A.json")
        env = { "LIVE_RUN" => "1", "BROKER_HOST" => "127.0.0.1" }
        mark_pending_at(path, run_id: "run-a", env: env)
        mark_pending_at(path, run_id: "run-b", env: env)
        assert_equal :not_pending, LiveSummary.replace_pending(path, "run-a", SYNTHETIC_SOURCE, summary_fields, env: env)
        assert_equal "run-b", JSON.parse(File.read(path))["run_id"]
      end
    end

    def test_replace_refuses_a_marker_written_for_other_source
      Dir.mktmpdir do |dir|
        path = File.join(dir, "PERSONA_A.json")
        env = { "LIVE_RUN" => "1", "BROKER_HOST" => "127.0.0.1" }
        mark_pending_at(path, run_id: "run-a", env: env)
        assert_equal :source_changed, LiveSummary.replace_pending(path, "run-a", "other-source", summary_fields, env: env)
        assert_equal true, JSON.parse(File.read(path))["pending"]
      end
    end

    private

    # What the release tasks fingerprint when they run from this checkout.
    def repo_source = @repo_source ||= LiveSummary.source_fingerprint(REPO_ROOT)

    def with_parallel_live_tasks
      original_app = Rake.application
      keys = %w[LIVE_RUN LIVE_RUN_ID BROKER_HOST BROKER_PROTOCOL PERSONA LIVE_SUMMARY_DIR LIVE_BUILD]
      saved = ENV.to_h.slice(*keys)
      Dir.mktmpdir do |dir|
        build = LiveSummary.pinned_build(File.join(REPO_ROOT, "data/fingerprints/rpms-ops.lock.yml"))
        write_summary(dir, "PERSONA_A.json", summary_fields("build" => build, "source" => repo_source))
        assert LiveSummary.check(dir: dir, build: build, source: repo_source).first, "fixture must start green"

        ENV.delete("LIVE_RUN")
        ENV.delete("LIVE_RUN_ID")
        ENV.update("BROKER_HOST" => "127.0.0.1", "BROKER_PROTOCOL" => "cia", "PERSONA" => "PERSONA_A",
                   "LIVE_SUMMARY_DIR" => dir, "LIVE_BUILD" => build)
        Rake.application = Rake::Application.new
        Rake.application.options.always_multitask = true # rake -m
        Rake::Task.define_task("test:live_settings") { ENV["LIVE_RUN"] = "1" }
        Rake::Task.define_task("test:live" => [ "test:live_settings" ])
        Rake::Task.define_task("release") { flunk "release action must not run after a failed live run" }
        load File.join(REPO_ROOT, "lib/tasks/release_guard.rake")

        yield File.join(dir, "PERSONA_A.json"), build
      end
    ensure
      keys.each { |key| saved.key?(key) ? ENV[key] = saved[key] : ENV.delete(key) }
      Rake.application = original_app
    end

    def summary_fields(overrides = {})
      {
        "schema" => 2,
        "build" => SYNTHETIC_BUILD,
        "build_source" => "pinned",
        "source" => SYNTHETIC_SOURCE,
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

    def refuse_check(dir, build: SYNTHETIC_BUILD, source: SYNTHETIC_SOURCE)
      ok, reasons = LiveSummary.check(dir: dir, build: build, source: source)
      refute ok
      refute_empty reasons
      [ ok, reasons ]
    end

    def mark_pending_at(path, **kwargs)
      env = kwargs.delete(:env) || { "LIVE_RUN" => "1", "BROKER_HOST" => "127.0.0.1" }
      run_id = kwargs.fetch(:run_id, SecureRandom.hex(8))
      pending_args = {
        persona: kwargs.fetch(:persona, "PERSONA_A"),
        protocol: kwargs.fetch(:protocol, "cia"),
        build: kwargs.fetch(:build, SYNTHETIC_BUILD),
        build_source: kwargs.fetch(:build_source, "pinned"),
        source: kwargs.fetch(:source, SYNTHETIC_SOURCE),
        run_id: run_id,
        env: env
      }
      LiveSummary.mark_pending(path, **pending_args)
    end
  end
end
