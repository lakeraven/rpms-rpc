# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../lib/rpms_rpc/security_keys"

class RpmsRpc::SecurityKeysTest < Minitest::Test
  def test_symbolize_known_keys
    result = RpmsRpc::SecurityKeys.symbolize([ "SD SUPERVISOR", "AGZMGR" ])
    assert_equal [ :scheduling_admin, :registration_manager ], result
  end

  def test_symbolize_ignores_unknown_keys
    result = RpmsRpc::SecurityKeys.symbolize([ "SD SUPERVISOR", "UNKNOWN KEY", "DGZSUP" ])
    assert_equal [ :scheduling_admin, :adt_supervisor ], result
  end

  def test_symbolize_empty
    assert_equal [], RpmsRpc::SecurityKeys.symbolize([])
  end

  def test_symbolize_nil
    assert_equal [], RpmsRpc::SecurityKeys.symbolize(nil)
  end

  def test_rpms_name
    assert_equal "SD SUPERVISOR", RpmsRpc::SecurityKeys.rpms_name(:scheduling_admin)
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

  # ADR 0008 rules 1-2: every key name the gem uses is a SECURITY KEY (#19.1)
  # on a built image, checked against a committed list (#314).
  KEY_LIST = File.expand_path("../../data/security_keys/bcer-9.0-20260930-8c88e47-ydb.txt", __dir__)

  def pinned_key_names
    File.readlines(KEY_LIST, chomp: true).reject { |l| l.empty? || l.start_with?("#") }
  end

  def test_every_registry_name_is_a_security_key_on_the_built_image
    missing = RpmsRpc::SecurityKeys::REGISTRY.values - pinned_key_names
    assert_empty missing, "not a SECURITY KEY (#19.1) on the pinned image: #{missing.inspect}"
  end

  def test_names_that_are_not_keys_are_gone
    removed = [
      "PRCFA SUPERVISOR", "PRCFA TECH", "BPRC MANAGER", "BGOZ CHS APPROVE", "BGOZ CHS CLERK", "GMRC MGR",
      "APCL VERIFY", "BGMH PROVIDER", "BGMH SUPERVISOR", "DENTP PROVIDER", "DENTP SUPERVISOR", "OR CPRS GUI CHART"
    ]
    assert_empty removed & RpmsRpc::SecurityKeys::REGISTRY.values
    assert_empty removed & pinned_key_names, "the pinned list confirms none of these is a key"
  end
end
