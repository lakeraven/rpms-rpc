# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"

# A client file required ON ITS OWN must be able to raise its own errors.
#
# RpmsRpc.sanitize_error lives in core.rb, and every raise site in the clients calls it. It was in
# version.rb and nothing required that, so `require "rpms_rpc/cia_client"` followed by any broker
# error gave NoMethodError instead of the real message. Found running the client against a live
# stack: the server had answered "The server rejected the requested action (R)" and the caller saw
# only "undefined method `sanitize_error' for module RpmsRpc".
#
# The boundary these tests guard: a client requires core.rb (module state, stdlib-only) and NOT
# version.rb (which also pulls the mappings, capability and role tables). Both halves matter —
# sanitize_error must resolve, and it must not cost the aggregate require to get there.
#
# This has to run in a FRESH interpreter: the test process has already loaded everything, which is
# exactly how the gap stayed hidden.
# The module is opened here rather than loaded: this file must not require the gem itself.
module RpmsRpc; end

class RpmsRpc::StandaloneRequireTest < Minitest::Test
  LIB = File.expand_path("../../lib", __dir__)

  # A standalone require must stay standalone. Requiring version.rb here would
  # drag in the mappings, capability and role tables a bare client never uses
  # (23 files against these 10). Pinned exactly, not capped: a ceiling lets
  # gradual bloat through, and the point is to notice the first extra file.
  # A legitimate new require means updating the number here, deliberately.
  STANDALONE_FILES = {
    "rpms_rpc/client" => 9,
    "rpms_rpc/cia_client" => 10,
    "rpms_rpc/xwb_client" => 10,
    "rpms_rpc/bmx_client" => 10
  }.freeze
  FEATURES = STANDALONE_FILES.keys.freeze

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
      expected = STANDALONE_FILES.fetch(feature)
      script = %(require "#{feature}"; print $LOADED_FEATURES.grep(%r{rpms_rpc}).sort.join("\n"))
      out, err, status = run_standalone(script)
      assert status.success?, err
      loaded = out.split("\n")
      assert_equal expected, loaded.size,
        "requiring only #{feature} loaded #{loaded.size} gem files, expected exactly #{expected}. " \
        "If version.rb crept back in, the tables came with it; if this is a deliberate new require, " \
        "update STANDALONE_FILES.\nLoaded:\n  #{loaded.map { |f| f.split("lib/").last }.join("\n  ")}"
    end
  end
end
