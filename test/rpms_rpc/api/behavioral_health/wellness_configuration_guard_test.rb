# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"

# Wellness must not monkey-patch RpmsRpc::Configuration (rpms-rpc#540 panel).
class BehavioralHealthWellnessConfigurationGuardTest < Minitest::Test
  LIB = File.expand_path("../../../../lib", __dir__)
  WELLNESS_RB = File.join(LIB, "rpms_rpc/api/behavioral_health/wellness.rb")
  CLEAN_ENV = { "RUBYOPT" => nil, "RUBYLIB" => nil, "BUNDLE_GEMFILE" => nil, "BUNDLER_SETUP" => nil }.freeze

  FORBIDDEN_SOURCE_FRAGMENTS = %w[post_bodies visit_key class\ Configuration].freeze

  def run_fresh(script)
    Open3.capture3(CLEAN_ENV, RbConfig.ruby, "-I", LIB, "-e", script)
  end

  def test_wellness_rb_source_does_not_reference_configuration_or_visit_reseed_ivars
    source = File.read(WELLNESS_RB)
    FORBIDDEN_SOURCE_FRAGMENTS.each do |fragment|
      refute_includes source, fragment,
                      "wellness.rb must not reference #{fragment.inspect} (test-only reseed belongs in tests)"
    end
  end

  def test_requiring_wellness_does_not_alter_rpms_rpc_configuration
    script = <<~RUBY
      require "rpms_rpc/core"
      ancestors_before = RpmsRpc::Configuration.ancestors.dup
      require "rpms_rpc/api/behavioral_health/wellness"
      owner = RpmsRpc::Configuration.instance_method(:client=).owner
      new_modules = RpmsRpc::Configuration.ancestors - ancestors_before
      if owner != RpmsRpc::Configuration || !new_modules.empty?
        print "altered"
      else
        print "ok"
      end
    RUBY

    out, err, status = run_fresh(script)
    assert status.success?, "subprocess failed:\n#{err}"
    assert_equal "ok", out,
                 "requiring wellness must leave Configuration#client= on Configuration " \
                 "and must not prepend modules to Configuration"
  end
end
