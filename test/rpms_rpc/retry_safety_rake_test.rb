# frozen_string_literal: true

require "minitest/autorun"
require "open3"

# rpms-rpc#110: rpc:retry_safety lint task (lib/tasks/retry_safety.rake).
class RpmsRpc::RetrySafetyRakeTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def test_rpc_retry_safety_task_exists_and_passes_on_the_committed_table
    env = { "LANG" => "C.UTF-8" }
    out, err, status = Open3.capture3(env, "bundle", "exec", "rake", "rpc:retry_safety", chdir: ROOT)

    assert status.success?, "rpc:retry_safety must exit 0 on the committed table:\n#{out}\n#{err}"
    combined = "#{out}#{err}"
    refute_match(/unclassified/i, combined)
    refute_match(/stale/i, combined)
  end
end
