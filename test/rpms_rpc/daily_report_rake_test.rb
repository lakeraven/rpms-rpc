# frozen_string_literal: true

require "minitest/autorun"
require "rake"

# rpms-rpc#365: rake report:daily is wired in lib/tasks/.
class RpmsRpc::DailyReportRakeTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_report_daily_task_is_defined
    original_app = Rake.application
    begin
      Rake.application = Rake::Application.new
      Rake.application.init("rake")
      load File.join(ROOT, "Rakefile")

      assert Rake::Task.task_defined?("report:daily"), "expected rake report:daily to be defined"
    ensure
      Rake.application = original_app
    end
  end
end
