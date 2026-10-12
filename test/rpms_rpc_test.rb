# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"

class RpmsRpcTest < Minitest::Test
  def test_version_is_defined
    refute_nil RpmsRpc::VERSION
  end

  def test_version_is_current
    assert_equal "0.4.0", RpmsRpc::VERSION
  end
end
