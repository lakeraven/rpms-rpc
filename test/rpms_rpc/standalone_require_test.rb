# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"

# A client file required ON ITS OWN must be able to raise its own errors.
#
# RpmsRpc.sanitize_error is defined in version.rb, and every raise site in the clients calls it.
# Nothing required version.rb, so `require "rpms_rpc/cia_client"` followed by any broker error gave
# NoMethodError instead of the real message. Found running the client against a live stack: the
# server had answered "The server rejected the requested action (R)" and the caller saw only
# "undefined method `sanitize_error' for module RpmsRpc".
#
# This has to run in a FRESH interpreter: the test process has already loaded everything, which is
# exactly how the gap stayed hidden.
# The module is opened here rather than loaded: this file must not require the gem itself.
module RpmsRpc; end

class RpmsRpc::StandaloneRequireTest < Minitest::Test
  LIB = File.expand_path("../../lib", __dir__)

  FEATURES = %w[rpms_rpc/client rpms_rpc/cia_client rpms_rpc/xwb_client rpms_rpc/bmx_client].freeze

  # A standalone require must stay standalone. Requiring version.rb here would
  # drag in the mappings, capability and role tables a bare client never uses,
  # so the count is pinned: core.rb is the one file the fix may add.
  MAX_STANDALONE_FILES = 12

  # The subprocess must not inherit this process's Ruby setup. RUBYOPT
  # (bundler/setup), RUBYLIB or a parent Gemfile can preload the gem, which
  # would satisfy the missing require and hide the very failure under test.
  CLEAN_ENV = { "RUBYOPT" => nil, "RUBYLIB" => nil, "BUNDLE_GEMFILE" => nil, "BUNDLER_SETUP" => nil }.freeze

  def run_standalone(script)
    Open3.capture3(CLEAN_ENV, RbConfig.ruby, "-I", LIB, "-e", script)
  end

  FEATURES.each do |feature|
    define_method("test_#{feature.tr("/", "_")}_alone_can_sanitize_an_error") do
      out, err, status = run_standalone(%(require "#{feature}"; print RpmsRpc.sanitize_error("CIA sign-on rejected")))
      assert status.success?, "requiring only #{feature} left sanitize_error undefined:\n#{err}"
      assert_equal "CIA sign-on rejected", out
    end

    define_method("test_#{feature.tr("/", "_")}_alone_does_not_eagerly_load_the_gem") do
      script = %(require "#{feature}"; print $LOADED_FEATURES.grep(%r{rpms_rpc}).size)
      out, err, status = run_standalone(script)
      assert status.success?, err
      loaded = out.to_i
      assert_operator loaded, :<=, MAX_STANDALONE_FILES,
        "requiring only #{feature} loaded #{loaded} gem files (max #{MAX_STANDALONE_FILES}) — " \
        "something pulled in version.rb and its tables instead of core.rb"
    end
  end
end
