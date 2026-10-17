# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tmpdir"

# rpms-rpc#110: rpc:retry_safety lint task (lib/tasks/retry_safety.rake).
class RpmsRpc::RetrySafetyRakeTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def test_rpc_retry_safety_task_exists_and_passes_on_the_committed_table
    env = { "LANG" => "C.UTF-8", "RETRY_SAFETY_TABLE" => nil }
    out, err, status = Open3.capture3(env, "bundle", "exec", "rake", "rpc:retry_safety", chdir: ROOT)

    assert status.success?, "rpc:retry_safety must exit 0 on the committed table:\n#{out}\n#{err}"
    combined = "#{out}#{err}"
    refute_match(/unclassified/i, combined)
    refute_match(/stale/i, combined)
  end

  def test_rpc_retry_safety_fails_when_table_is_missing_a_method
    committed = File.join(ROOT, "lib/rpms_rpc/retry_safety.yml")
    removed_label = "RpmsRpc::Patient.find"
    table_body = File.readlines(committed).reject do |line|
      line.start_with?("\"#{removed_label}\":")
    end

    Dir.mktmpdir do |dir|
      path = File.join(dir, "retry_safety.yml")
      File.write(path, table_body.join)
      env = { "LANG" => "C.UTF-8", "RETRY_SAFETY_TABLE" => path }
      out, err, status = Open3.capture3(env, "bundle", "exec", "rake", "rpc:retry_safety", chdir: ROOT)

      refute status.success?, "rpc:retry_safety must fail when the table omits a public method:\n#{out}\n#{err}"
      combined = "#{out}#{err}"
      assert_match(/unclassified:\s*#{removed_label}/, combined)
    end
  end

  def test_rpc_retry_safety_fails_when_table_has_a_stale_entry
    committed = File.join(ROOT, "lib/rpms_rpc/retry_safety.yml")
    stale_label = "RpmsRpc::Patient.__synthetic_stale__"
    table_body = File.read(committed) + "\"#{stale_label}\": read\n"

    Dir.mktmpdir do |dir|
      path = File.join(dir, "retry_safety.yml")
      File.write(path, table_body)
      env = { "LANG" => "C.UTF-8", "RETRY_SAFETY_TABLE" => path }
      out, err, status = Open3.capture3(env, "bundle", "exec", "rake", "rpc:retry_safety", chdir: ROOT)

      refute status.success?, "rpc:retry_safety must fail when the table has a stale key:\n#{out}\n#{err}"
      combined = "#{out}#{err}"
      assert_match(/stale:\s*#{stale_label}/, combined)
    end
  end
end
