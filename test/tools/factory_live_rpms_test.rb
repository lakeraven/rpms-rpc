# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"

# bin/factory_live_rpms is the SessionStart hook that starts the pinned RPMS release in an
# environment that sets FACTORY_LIVE_RPMS=1. These runs use a stub in place of bin/cloud_rpms and a
# fake lakeraven-ehr checkout, so nothing touches Docker or the network.
class FactoryLiveRpmsTest < Minitest::Test
  SCRIPT = File.expand_path("../../bin/factory_live_rpms", __dir__)
  SETTINGS = File.expand_path("../../.claude/settings.json", __dir__)

  def setup
    @tmp = Dir.mktmpdir("live")
    @state = File.join(@tmp, "state")
    @ehr = File.join(@tmp, "ehr")
    FileUtils.mkdir_p(@ehr)
    File.write(File.join(@ehr, "compose.yml"), "services: {}\n")
    @calls = File.join(@tmp, "calls")
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def stub(exit_code: 0, sleep_for: 0)
    path = File.join(@tmp, "cloud_rpms")
    File.write(path, <<~SH)
      #!/usr/bin/env bash
      echo $$ $PPID > #{@tmp}/pids
      echo "$PINNED $LAKERAVEN_EHR_PATH ${RPMS_IMAGE:-} ${RPMS_TAG:-} $*" >> #{@calls}
      sleep #{sleep_for}
      exit #{exit_code}
    SH
    File.chmod(0o755, path)
    path
  end

  def run_hook(env)
    base = { "FACTORY_LIVE_RPMS" => nil, "RPMS_IMAGE" => nil, "RPMS_TAG" => nil,
             "FACTORY_LIVE_RPMS_DIR" => @state, "LAKERAVEN_EHR_PATH" => @ehr }
    system(base.merge(env), SCRIPT, out: File::NULL, err: File::NULL)
  end

  def status
    File.read(File.join(@state, "status")).strip
  end

  def wait_for(want)
    50.times do
      return if File.exist?(File.join(@state, "status")) && status == want
      sleep 0.1
    end
    flunk "status never became #{want} (is #{File.exist?(File.join(@state, 'status')) ? status : 'missing'})"
  end

  def calls
    File.exist?(@calls) ? File.readlines(@calls, chomp: true) : []
  end

  def test_unset_flag_does_nothing
    assert run_hook("CLOUD_RPMS" => stub)
    refute File.exist?(@state)
    assert_empty calls
  end

  def test_flag_starts_the_pinned_release_in_the_background
    assert run_hook("FACTORY_LIVE_RPMS" => "1", "CLOUD_RPMS" => stub)
    wait_for("healthy")
    assert_equal [ "1 #{@ehr}   up" ], calls
  end

  def test_returns_before_the_stack_is_up
    started = Time.now
    assert run_hook("FACTORY_LIVE_RPMS" => "1", "CLOUD_RPMS" => stub(sleep_for: 3))
    assert_operator Time.now - started, :<, 2
    assert_equal "starting", status
    wait_for("healthy")
  end

  def test_a_failed_start_still_exits_zero_and_records_failed
    assert run_hook("FACTORY_LIVE_RPMS" => "1", "CLOUD_RPMS" => stub(exit_code: 1))
    wait_for("failed")
  end

  def test_second_start_does_not_start_a_second_copy
    cmd = stub
    assert run_hook("FACTORY_LIVE_RPMS" => "1", "CLOUD_RPMS" => cmd)
    wait_for("healthy")
    assert run_hook("FACTORY_LIVE_RPMS" => "1", "CLOUD_RPMS" => cmd)
    sleep 0.3
    assert_equal 1, calls.size
  end

  def test_start_while_a_run_is_in_progress_starts_nothing
    cmd = stub(sleep_for: 1)
    assert run_hook("FACTORY_LIVE_RPMS" => "1", "CLOUD_RPMS" => cmd)
    assert run_hook("FACTORY_LIVE_RPMS" => "1", "CLOUD_RPMS" => cmd)
    wait_for("healthy")
    assert_equal 1, calls.size
  end

  def test_inherited_image_overrides_do_not_replace_the_pin
    assert run_hook("FACTORY_LIVE_RPMS" => "1", "CLOUD_RPMS" => stub,
                    "RPMS_IMAGE" => "other:image", "RPMS_TAG" => "other-tag")
    wait_for("healthy")
    assert_equal [ "1 #{@ehr}   up" ], calls
  end

  def test_start_after_a_killed_run_tries_again
    assert run_hook("FACTORY_LIVE_RPMS" => "1", "CLOUD_RPMS" => stub(sleep_for: 30))
    50.times { break if File.exist?(File.join(@tmp, "pids")); sleep 0.1 }
    File.read(File.join(@tmp, "pids")).split.each do |pid|
      Process.kill("KILL", pid.to_i)
    rescue Errno::ESRCH
      nil
    end
    sleep 0.3
    assert_equal "starting", status
    assert run_hook("FACTORY_LIVE_RPMS" => "1", "CLOUD_RPMS" => stub)
    wait_for("healthy")
    assert_equal 2, calls.size
  end

  def test_a_state_directory_owned_by_someone_else_or_a_symlink_is_refused
    target = File.join(@tmp, "elsewhere")
    FileUtils.mkdir_p(target)
    File.symlink(target, @state)
    assert run_hook("FACTORY_LIVE_RPMS" => "1", "CLOUD_RPMS" => stub)
    sleep 0.3
    assert_empty Dir.children(target)
    assert_empty calls
  end

  def test_start_after_a_failure_tries_again
    assert run_hook("FACTORY_LIVE_RPMS" => "1", "CLOUD_RPMS" => stub(exit_code: 1))
    wait_for("failed")
    assert run_hook("FACTORY_LIVE_RPMS" => "1", "CLOUD_RPMS" => stub)
    wait_for("healthy")
    assert_equal 2, calls.size
  end

  def test_settings_run_it_at_session_startup
    hooks = JSON.parse(File.read(SETTINGS)).dig("hooks", "SessionStart")
    commands = hooks.select { |h| h["matcher"] == "startup" }.flat_map { |h| h["hooks"] }.map { |h| h["command"] }
    assert(commands.any? { |c| c.include?("bin/factory_live_rpms") })
  end
end
