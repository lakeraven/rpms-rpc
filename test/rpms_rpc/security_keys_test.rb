# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../lib/rpms_rpc/security_keys"

class RpmsRpc::SecurityKeysTest < Minitest::Test
  def test_symbolize_known_keys
    result = RpmsRpc::SecurityKeys.symbolize(["PRCFA SUPERVISOR", "GMRC MGR"])
    assert_equal [:prc_supervisor, :consult_manager], result
  end

  def test_symbolize_ignores_unknown_keys
    result = RpmsRpc::SecurityKeys.symbolize(["PRCFA SUPERVISOR", "UNKNOWN KEY", "OR CPRS GUI CHART"])
    assert_equal [:prc_supervisor, :cprs_gui_chart], result
  end

  def test_symbolize_empty
    assert_equal [], RpmsRpc::SecurityKeys.symbolize([])
  end

  def test_symbolize_nil
    assert_equal [], RpmsRpc::SecurityKeys.symbolize(nil)
  end

  def test_rpms_name
    assert_equal "PRCFA SUPERVISOR", RpmsRpc::SecurityKeys.rpms_name(:prc_supervisor)
    assert_equal "GMRC MGR", RpmsRpc::SecurityKeys.rpms_name(:consult_manager)
    assert_nil RpmsRpc::SecurityKeys.rpms_name(:nonexistent)
  end

  def test_registry_is_frozen
    assert RpmsRpc::SecurityKeys::REGISTRY.frozen?
  end
end
