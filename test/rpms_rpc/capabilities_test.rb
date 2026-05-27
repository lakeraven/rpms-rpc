# frozen_string_literal: true

require "minitest/autorun"
require "set"
require_relative "../../lib/rpms_rpc/version"
require_relative "../../lib/rpms_rpc/capabilities"
require_relative "../../lib/rpms_rpc/mock_client"

class RpmsRpc::CapabilitiesTest < Minitest::Test
  User = Struct.new(:user_type, :security_keys, keyword_init: true)
  ImagingUser = Struct.new(:duz, keyword_init: true)

  def test_can_approve_chs_with_supervisor_key
    user = User.new(user_type: "case_manager", security_keys: [ :prc_supervisor ])
    assert RpmsRpc::Capabilities.can_approve_chs?(user)
  end

  def test_can_approve_chs_with_manager_key
    user = User.new(user_type: "case_manager", security_keys: [ :prc_manager ])
    assert RpmsRpc::Capabilities.can_approve_chs?(user)
  end

  def test_cannot_approve_chs_without_keys
    user = User.new(user_type: "clerk", security_keys: [])
    refute RpmsRpc::Capabilities.can_approve_chs?(user)
  end

  def test_can_process_chs
    user = User.new(user_type: "clerk", security_keys: [ :prc_tech ])
    assert RpmsRpc::Capabilities.can_process_chs?(user)
  end

  def test_can_manage_consults
    user = User.new(user_type: "nurse", security_keys: [ :consult_manager ])
    assert RpmsRpc::Capabilities.can_manage_consults?(user)
  end

  def test_cannot_manage_consults_without_key
    user = User.new(user_type: "nurse", security_keys: [])
    refute RpmsRpc::Capabilities.can_manage_consults?(user)
  end

  def test_can_access_behavioral_health
    user = User.new(user_type: "provider", security_keys: [ :bh_provider ])
    assert RpmsRpc::Capabilities.can_access_behavioral_health?(user)
  end

  def test_can_access_dental
    user = User.new(user_type: "provider", security_keys: [ :dental_supervisor ])
    assert RpmsRpc::Capabilities.can_access_dental?(user)
  end

  def test_role_permissions_for_provider
    user = User.new(user_type: "provider", security_keys: [])
    perms = RpmsRpc::Capabilities.permissions_for(user)
    assert_includes perms, :view_patients
    assert_includes perms, :create_referrals
    refute_includes perms, :approve_referrals
  end

  def test_role_permissions_for_nurse
    user = User.new(user_type: "nurse", security_keys: [])
    perms = RpmsRpc::Capabilities.permissions_for(user)
    assert_includes perms, :view_patients
    assert_includes perms, :update_referral_status
    refute_includes perms, :create_referrals
  end

  def test_role_permissions_for_clerk
    user = User.new(user_type: "clerk", security_keys: [])
    perms = RpmsRpc::Capabilities.permissions_for(user)
    assert_includes perms, :view_patients
    refute_includes perms, :create_referrals
    refute_includes perms, :approve_referrals
  end

  def test_can_check
    user = User.new(user_type: "provider", security_keys: [])
    assert RpmsRpc::Capabilities.can?(user, :view_patients)
    refute RpmsRpc::Capabilities.can?(user, :approve_referrals)
  end

  def test_capabilities_for_merges_role_and_keys
    user = User.new(user_type: "clerk", security_keys: [ :prc_tech ])
    caps = RpmsRpc::Capabilities.capabilities_for(user)
    assert_includes caps, :view_patients       # from role
    assert_includes caps, :process_claims      # from key
    refute_includes caps, :create_referrals    # not in clerk role
  end

  def test_capabilities_for_case_manager_with_supervisor
    user = User.new(user_type: "case_manager", security_keys: [ :prc_supervisor ])
    caps = RpmsRpc::Capabilities.capabilities_for(user)
    assert_includes caps, :manage_referrals     # from role
    assert_includes caps, :approve_referrals    # from role + key
    assert_includes caps, :process_claims       # from key
  end

  def test_unknown_role_defaults_to_user
    user = User.new(user_type: "unknown", security_keys: [])
    perms = RpmsRpc::Capabilities.permissions_for(user)
    assert_equal [ :view_own_referrals ], perms
  end

  # --- imaging_user? (RPC-backed) ------------------------------------------

  def test_imaging_user_is_true_when_user_has_mag_keys
    RpmsRpc::Capabilities.clear_imaging_cache!
    RpmsRpc.mock! do |m|
      m.seed_keyed_collection(:imaging_user_keys, "301", [
        { key_name: "MAG WINDOWS" }
      ])
    end

    user = ImagingUser.new(duz: "301")
    assert RpmsRpc::Capabilities.imaging_user?(user)
  end

  def test_imaging_user_is_false_when_user_has_no_mag_keys
    RpmsRpc::Capabilities.clear_imaging_cache!
    RpmsRpc.mock! do |m|
      m.seed_keyed_collection(:imaging_user_keys, "999", [])
    end

    user = ImagingUser.new(duz: "999")
    refute RpmsRpc::Capabilities.imaging_user?(user)
  end

  def test_imaging_user_caches_per_user_so_chart_open_does_not_rehit_rpc
    RpmsRpc::Capabilities.clear_imaging_cache!
    RpmsRpc.mock! do |m|
      m.seed_keyed_collection(:imaging_user_keys, "301", [
        { key_name: "MAG WINDOWS" }
      ])
    end

    user = ImagingUser.new(duz: "301")
    5.times { RpmsRpc::Capabilities.imaging_user?(user) }

    rpcs = RpmsRpc.client.received_calls.count { |c| c[:rpc] == "MAGGUSERKEYS" }
    assert_equal 1, rpcs
  end

  def test_imaging_user_is_false_for_blank_or_invalid_duz
    refute RpmsRpc::Capabilities.imaging_user?(ImagingUser.new(duz: nil))
    refute RpmsRpc::Capabilities.imaging_user?(ImagingUser.new(duz: ""))
    refute RpmsRpc::Capabilities.imaging_user?(nil)
  end

  def test_clear_imaging_cache_forces_redispatch
    RpmsRpc::Capabilities.clear_imaging_cache!
    RpmsRpc.mock! do |m|
      m.seed_keyed_collection(:imaging_user_keys, "301", [
        { key_name: "MAG WINDOWS" }
      ])
    end

    user = ImagingUser.new(duz: "301")
    RpmsRpc::Capabilities.imaging_user?(user)
    RpmsRpc::Capabilities.clear_imaging_cache!
    RpmsRpc::Capabilities.imaging_user?(user)

    rpcs = RpmsRpc.client.received_calls.count { |c| c[:rpc] == "MAGGUSERKEYS" }
    assert_equal 2, rpcs, "expected clear_imaging_cache! to force a second RPC dispatch"
  end
end
