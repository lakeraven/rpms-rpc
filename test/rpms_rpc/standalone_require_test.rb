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

  %w[rpms_rpc/client rpms_rpc/cia_client rpms_rpc/xwb_client rpms_rpc/bmx_client].each do |feature|
    define_method("test_#{feature.tr("/", "_")}_alone_can_sanitize_an_error") do
      script = %(require "#{feature}"; print RpmsRpc.sanitize_error("CIA sign-on rejected"))
      out, err, status = Open3.capture3(RbConfig.ruby, "-I", LIB, "-e", script)
      assert status.success?, "requiring only #{feature} left sanitize_error undefined:\n#{err}"
      assert_equal "CIA sign-on rejected", out
    end
  end
end
