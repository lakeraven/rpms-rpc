# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../lib/rpms_rpc/security_keys"

class RpmsRpc::SecurityKeysTest < Minitest::Test
  def test_symbolize_known_keys
    result = RpmsRpc::SecurityKeys.symbolize([ "PRCFA SUPERVISOR", "GMRC MGR" ])
    assert_equal [ :prc_supervisor, :consult_manager ], result
  end

  def test_symbolize_ignores_unknown_keys
    result = RpmsRpc::SecurityKeys.symbolize([ "PRCFA SUPERVISOR", "UNKNOWN KEY", "OR CPRS GUI CHART" ])
    assert_equal [ :prc_supervisor, :cprs_gui_chart ], result
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

  # The keys BPRM v4 gates registration, scheduling and ADT on (#296).
  REGISTRATION_SCHEDULING_ADT_KEYS = {
    registration_menu: "AGZMENU",
    registration_manager: "AGZMGR",
    registration_view_only: "AGZVIEWONLY",
    registration_view_ssn: "AGZVIEWSSN",
    benefits_case_reopen: "AGZCREOPN",
    scheduling_menu: "SDZMENU",
    scheduling_supervisor: "SDZSUP",
    scheduling_registration_menu: "SDZREGMENU",
    adt_menu: "DGZMENU",
    adt_movement: "DGZADT",
    adt_nurse: "DGZNUR",
    adt_supervisor: "DGZSUP",
    adt_system: "DGZSYS",
    adt_incomplete_chart: "DGZICE",
    adt_pcc: "DGZPCC"
  }.freeze

  def test_registration_scheduling_adt_keys_are_pinned_to_their_rpms_names
    REGISTRATION_SCHEDULING_ADT_KEYS.each do |symbol, rpms_name|
      assert_equal rpms_name, RpmsRpc::SecurityKeys.rpms_name(symbol), "#{symbol} must name #{rpms_name}"
    end
  end

  def test_registration_scheduling_adt_keys_round_trip_through_symbolize
    REGISTRATION_SCHEDULING_ADT_KEYS.each do |symbol, rpms_name|
      assert_equal [ symbol ], RpmsRpc::SecurityKeys.symbolize([ rpms_name ]), "#{rpms_name} must symbolize to #{symbol}"
    end
  end

  def test_symbolize_names_a_view_only_registration_user
    assert_equal [ :registration_view_only ], RpmsRpc::SecurityKeys.symbolize([ "AGZVIEWONLY" ])
  end

  def test_scheduling_supervisor_key_is_distinct_from_sd_supervisor
    assert_equal "SDZSUP", RpmsRpc::SecurityKeys.rpms_name(:scheduling_supervisor)
    assert_equal "SD SUPERVISOR", RpmsRpc::SecurityKeys.rpms_name(:scheduling_admin)
  end

  def test_registry_has_no_duplicate_rpms_names
    names = RpmsRpc::SecurityKeys::REGISTRY.values
    assert_equal names.uniq, names, "every RPMS key name must map back to exactly one symbol"
  end
end
