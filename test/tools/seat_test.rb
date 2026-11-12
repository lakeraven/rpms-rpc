# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"

# Contract for bin/seat when Cursor is out of usage.
#
# Every role prints `SEAT_FALLBACK role=<role> model=<m>` and exits 75, so the caller plays
# it with a native subagent. gate2 (and probe) first try the Codex CLI: a Codex run prints
# `SEAT_VENDOR role=gate2 vendor=openai model=<id>` and keeps its own exit code. Codex that
# is missing, signed out or refuses the model still ends in the native fallback. Codex runs
# read-only, ignoring the user's Codex config (so no MCP servers), without the Cursor or GitHub
# tokens.
#
# The Cursor agent and the Codex CLI are stand-ins written by the test: what is under test is
# the script's routing, not either vendor.
class SeatTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  SCRIPT = File.join(ROOT, "bin", "seat")

  OUT_OF_USAGE = <<~SH
    #!/bin/sh
    echo "ActionRequiredError: You're out of usage" >&2
    exit 1
  SH

  ANSWERS = <<~SH
    #!/bin/sh
    echo "cursor answered"
    exit 0
  SH

  def with_seat(agent:, codex: nil)
    Dir.mktmpdir("seat-test") do |dir|
      home = File.join(dir, "home")
      bin = File.join(dir, "bin")
      FileUtils.mkdir_p([ File.join(home, ".local", "bin"), bin ])
      write_exe(File.join(home, ".local", "bin", "agent"), agent)
      write_exe(File.join(bin, "codex"), codex) if codex
      File.write(File.join(dir, "brief.md"), "Review this diff.\n")
      env = {
        "HOME" => home,
        "PATH" => "#{bin}:/usr/bin:/bin",
        "TMPDIR" => dir,
        "CURSOR_API_KEY" => "cursor-secret",
        "GH_TOKEN" => "gh-secret",
        "GITHUB_TOKEN" => "github-secret"
      }
      yield(dir, env)
    end
  end

  def write_exe(path, body)
    File.write(path, body)
    File.chmod(0o755, path)
  end

  # A stand-in Codex that records its arguments and environment, then answers.
  def recording_codex(dir, reply: "PROBE_OK", status: 0, stderr: "")
    <<~SH
      #!/bin/sh
      printf '%s\\n' "$@" > "#{dir}/codex-args"
      env > "#{dir}/codex-env"
      [ -n "#{stderr}" ] && echo "#{stderr}" >&2
      echo "#{reply}"
      exit #{status}
    SH
  end

  def seat(env, dir, *args)
    out, err, status = Open3.capture3(env, SCRIPT, *args, chdir: dir)
    [ out, err, status.exitstatus ]
  end

  def test_gate2_runs_on_codex_when_cursor_is_out_of_usage
    with_seat(agent: OUT_OF_USAGE) do |dir, env|
      write_exe(File.join(dir, "bin", "codex"), recording_codex(dir, reply: "no findings"))
      out, _err, code = seat(env, dir, "gate2", "brief.md")

      assert_equal 0, code
      assert_match(/^SEAT_VENDOR role=gate2 vendor=openai model=\S+$/, out)
      assert_includes out, "no findings"
      refute_includes out, "SEAT_FALLBACK"

      args = File.read(File.join(dir, "codex-args")).lines.map(&:chomp)
      assert_equal "exec", args.first
      assert_equal "read-only", args[args.index("--sandbox") + 1]
      assert_includes args, "--ignore-user-config"
      assert_includes args.last, "Review this diff."

      codex_env = File.read(File.join(dir, "codex-env"))
      refute_includes codex_env, "cursor-secret"
      refute_includes codex_env, "gh-secret"
      refute_includes codex_env, "github-secret"
    end
  end

  def test_probe_answers_through_codex_when_cursor_is_out_of_usage
    with_seat(agent: OUT_OF_USAGE) do |dir, env|
      write_exe(File.join(dir, "bin", "codex"), recording_codex(dir))
      out, _err, code = seat(env, dir, "probe")

      assert_equal 0, code
      assert_includes out, "PROBE_OK"
      assert_match(/^SEAT_VENDOR role=gate2 vendor=openai/, out)
    end
  end

  def test_gate2_falls_back_to_native_opus_when_codex_is_not_installed
    with_seat(agent: OUT_OF_USAGE) do |dir, env|
      out, _err, code = seat(env, dir, "gate2", "brief.md")

      assert_equal 75, code
      assert_equal "SEAT_FALLBACK role=gate2 model=opus", out.lines.last.chomp
      refute_includes out, "SEAT_VENDOR"
    end
  end

  def test_gate2_falls_back_to_native_opus_when_the_plan_refuses_the_codex_model
    with_seat(agent: OUT_OF_USAGE) do |dir, env|
      refused = recording_codex(dir, reply: "", status: 1,
        stderr: "ERROR: The 'gpt-6-sol' model is not supported when using Codex with a ChatGPT account.")
      write_exe(File.join(dir, "bin", "codex"), refused)
      out, _err, code = seat(env, dir, "gate2", "brief.md")

      assert_equal 75, code
      assert_equal "SEAT_FALLBACK role=gate2 model=opus", out.lines.last.chomp
      refute_includes out, "SEAT_VENDOR"
    end
  end

  def test_a_codex_run_that_started_and_failed_keeps_its_own_exit_code
    with_seat(agent: OUT_OF_USAGE) do |dir, env|
      write_exe(File.join(dir, "bin", "codex"), recording_codex(dir, reply: "crashed", status: 3))
      out, _err, code = seat(env, dir, "gate2", "brief.md")

      assert_equal 3, code
      refute_includes out, "SEAT_FALLBACK"
      assert_match(/^SEAT_VENDOR role=gate2 vendor=openai/, out)
    end
  end

  def test_a_failed_codex_review_that_quotes_an_error_phrase_keeps_its_exit_code
    with_seat(agent: OUT_OF_USAGE) do |dir, env|
      quoting = recording_codex(dir, reply: "bin/seat:118 greps for usage limit and codex login", status: 3)
      write_exe(File.join(dir, "bin", "codex"), quoting)
      out, _err, code = seat(env, dir, "gate2", "brief.md")

      assert_equal 3, code
      refute_includes out, "SEAT_FALLBACK"
      assert_match(/^SEAT_VENDOR role=gate2 vendor=openai/, out)
    end
  end

  def test_codex_is_not_used_while_cursor_answers
    with_seat(agent: ANSWERS) do |dir, env|
      write_exe(File.join(dir, "bin", "codex"), recording_codex(dir))
      out, _err, code = seat(env, dir, "gate2", "brief.md")

      assert_equal 0, code
      assert_includes out, "cursor answered"
      refute_path_exists File.join(dir, "codex-args")
    end
  end

  def test_other_roles_still_fall_back_to_their_native_model_never_to_codex
    { "spec" => "fable", "build" => "sonnet", "build-hard" => "opus", "gate" => "fable" }.each do |role, model|
      with_seat(agent: OUT_OF_USAGE) do |dir, env|
        write_exe(File.join(dir, "bin", "codex"), recording_codex(dir))
        out, _err, code = seat(env, dir, role, "brief.md")

        assert_equal 75, code, role
        assert_equal "SEAT_FALLBACK role=#{role} model=#{model}", out.lines.last.chomp
        refute_path_exists File.join(dir, "codex-args")
      end
    end
  end
end
