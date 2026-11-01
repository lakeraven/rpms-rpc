# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"

# Wellness must load without the full gem entry point and must resolve FileMan
# context at runtime (rpms-rpc#540). Checked in a fresh interpreter.
module RpmsRpc; end

class BehavioralHealthWellnessStandaloneLoadTest < Minitest::Test
  LIB = File.expand_path("../../../../lib", __dir__)
  CLEAN_ENV = { "RUBYOPT" => nil, "RUBYLIB" => nil, "BUNDLE_GEMFILE" => nil, "BUNDLER_SETUP" => nil }.freeze

  def run_fresh(script)
    Open3.capture3(CLEAN_ENV, RbConfig.ruby, "-I", LIB, "-e", script)
  end

  def test_wellness_alone_hits_save_error_not_name_error_on_fileman_path
    script = <<~RUBY
      require "rpms_rpc/core"
      require "rpms_rpc/mock_client"
      require "rpms_rpc/mappings/amhg_wellness"
      require "rpms_rpc/api/behavioral_health/wellness"

      mock = RpmsRpc.mock!
      RpmsRpc.configure { |c| c.client = mock }

      begin
        RpmsRpc::BehavioralHealth::Wellness.save_measurements(
          "8840",
          patient: "990540",
          measurements: [ { type: "PHQ9", value: 14, provider: "412" } ]
        )
        print "unexpected success"
      rescue NameError
        print "NameError"
      rescue RpmsRpc::BehavioralHealth::Wellness::SaveError
        print "SaveError"
      end
    RUBY

    out, err, status = run_fresh(script)
    assert status.success?, "subprocess failed:\n#{err}"
    assert_equal "SaveError", out,
                 "requiring only wellness must not NameError on Patient::FILEMAN_CONTEXT during DDR work"
  end
end
