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

  # No broker is needed to reach the FileMan context: the lock is its first
  # use. The client is a dropped wire, so the save fails on its first RPC;
  # the failure must be that wire, not a constant Wellness did not load.
  def test_wellness_alone_reaches_the_fileman_context_and_fails_on_the_wire
    script = <<~RUBY
      require "rpms_rpc/core"
      require "rpms_rpc/mappings/amhg_wellness"
      require "rpms_rpc/api/behavioral_health/wellness"

      wire_down = Object.new
      def wire_down.method_missing(name, *) = name.to_s.start_with?("call_rpc") ? raise(IOError, "no broker") : super
      def wire_down.respond_to_missing?(name, include_private = false) = name.to_s.start_with?("call_rpc") || super
      RpmsRpc.configure { |c| c.client = wire_down }

      begin
        RpmsRpc::BehavioralHealth::Wellness.save_measurements(
          "8840",
          patient: "990540",
          measurements: [ { type: "PHQ9", value: 14, provider: "412" } ]
        )
        print "unexpected success"
      rescue NameError
        print "NameError"
      rescue RpmsRpc::BehavioralHealth::Wellness::SaveError => e
        print "SaveError caused by \#{e.cause.class}"
      end
    RUBY

    out, err, status = run_fresh(script)
    assert status.success?, "subprocess failed:\n#{err}"
    assert_equal "SaveError caused by IOError", out,
                 "requiring only wellness must not NameError on Patient::FILEMAN_CONTEXT during DDR work"
  end

  def test_wellness_save_error_is_subclass_of_behavioral_health_save_error_in_fresh_interpreter
    script = <<~RUBY
      require "rpms_rpc/core"
      require "rpms_rpc/mappings/amhg_wellness"
      require "rpms_rpc/api/behavioral_health/wellness"

      print(
        RpmsRpc::BehavioralHealth::Wellness::SaveError < RpmsRpc::BehavioralHealth::SaveError
      )
    RUBY

    out, err, status = run_fresh(script)
    assert status.success?, "subprocess failed:\n#{err}"
    assert_equal "true", out.strip,
                 "Wellness::SaveError must inherit BehavioralHealth::SaveError (#568 parity)"
  end
end
