# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"

# `require "rpms_rpc"` is the gem's one way in (#7), and `rpms_rpc/version`
# defines only VERSION. Both are checked in a FRESH interpreter: this test
# process has already loaded everything, which would hide a missing require.
# The module is opened here rather than loaded: this file must not require the gem itself.
module RpmsRpc; end

class RpmsRpc::EntryPointTest < Minitest::Test
  LIB = File.expand_path("../../lib", __dir__)
  API_DIR = File.join(LIB, "rpms_rpc", "api")

  # See standalone_require_test.rb: the subprocess must not inherit a preload.
  CLEAN_ENV = { "RUBYOPT" => nil, "RUBYLIB" => nil, "BUNDLE_GEMFILE" => nil, "BUNDLER_SETUP" => nil }.freeze

  def run_fresh(script)
    out, err, status = Open3.capture3(CLEAN_ENV, RbConfig.ruby, "-I", LIB, "-e", script)
    assert status.success?, "subprocess failed:\n#{err}"
    out
  end

  # AC 1: the single require is enough for the configuration surface.
  def test_require_rpms_rpc_alone_configures_a_mock_client
    out = run_fresh(<<~RUBY)
      require "rpms_rpc"
      mock = RpmsRpc.mock!
      raise "mock! did not configure the client" unless RpmsRpc.client.equal?(mock)
      RpmsRpc.reset!
      begin
        RpmsRpc.client
        raise "reset! left a client configured"
      rescue RpmsRpc::NotConfiguredError
      end
      RpmsRpc.configure { |c| c.client = mock }
      raise "configure did not set the client" unless RpmsRpc.client.equal?(mock)
      print RpmsRpc::Configuration.new.class
    RUBY
    assert_equal "RpmsRpc::Configuration", out
  end

  # AC 2: the single require loads the public API: tables, mappings, API modules.
  def test_require_rpms_rpc_alone_loads_the_public_api
    out = run_fresh(<<~RUBY)
      require "rpms_rpc"
      %w[DataMapper SecurityKeys UserRoles Capabilities].each { |c| RpmsRpc.const_get(c) }
      RpmsRpc::DataMapper[:patient_select]
      print $LOADED_FEATURES.grep(%r{rpms_rpc/api/}).map { |f| f.split("lib/").last }.sort.join("\\n")
    RUBY
    expected = Dir[File.join(API_DIR, "**", "*.rb")].map { |f| f.split("lib/").last }.sort
    assert_equal expected, out.split("\n"), "require \"rpms_rpc\" must load every module under lib/rpms_rpc/api"
  end

  # AC 3: version.rb defines VERSION and nothing else.
  def test_version_rb_defines_only_version
    out = run_fresh(<<~RUBY)
      require "rpms_rpc/version"
      print RpmsRpc.constants.sort.inspect, "|", RpmsRpc.respond_to?(:configure), "|", RpmsRpc.respond_to?(:mock!)
    RUBY
    assert_equal "[:VERSION]|false|false", out
  end

  # AC 4: the gemspec loads version.rb, so loading the gemspec loads one gem file.
  def test_gemspec_loads_only_the_version_file
    gemspec = File.expand_path("../../rpms-rpc.gemspec", __dir__)
    out = run_fresh(<<~RUBY)
      spec = Gem::Specification.load(#{gemspec.inspect})
      print spec.version, "|", $LOADED_FEATURES.grep(%r{rpms_rpc/}).map { |f| f.split("lib/").last }.join(",")
    RUBY
    version, loaded = out.split("|", 2)
    refute_empty version
    assert_equal "rpms_rpc/version.rb", loaded
  end
end
