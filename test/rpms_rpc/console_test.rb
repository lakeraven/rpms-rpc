# frozen_string_literal: true

require "minitest/autorun"
require "open3"

# bin/console must refuse to start when a required setting is missing, and the
# message must name what is missing — never silently connect to a default host
# or fall back to a default credential.
class ConsoleTest < Minitest::Test
  CONSOLE = File.expand_path("../../bin/console", __dir__)

  # A clean environment with none of the console's settings present.
  def run_console(env)
    base = %w[BROKER BROKER_HOST BROKER_PORT RPMS_ACCESS RPMS_VERIFY RPMS_CONTEXT]
    clean = ENV.to_h.reject { |k, _| base.include?(k) }
    Open3.capture3(clean.merge(env), RbConfig.ruby, CONSOLE)
  end

  def test_refuses_to_start_with_no_settings
    _out, err, status = run_console({})
    refute status.success?, "console must exit non-zero when settings are missing"
    assert_match(/refusing to start/i, err)
    %w[BROKER BROKER_HOST BROKER_PORT RPMS_ACCESS RPMS_VERIFY].each do |k|
      assert_match(/#{k}/, err, "the refusal must name the missing #{k}")
    end
  end

  def test_refusal_names_only_the_missing_settings
    _out, err, status = run_console(
      "BROKER" => "cia", "BROKER_HOST" => "127.0.0.1", "BROKER_PORT" => "19200"
    )
    refute status.success?
    assert_match(/RPMS_ACCESS/, err)
    assert_match(/RPMS_VERIFY/, err)
    # Those that WERE provided must not be reported missing.
    refute_match(/missing:[^\n]*BROKER_HOST/, err)
  end
end
