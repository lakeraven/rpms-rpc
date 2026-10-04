# frozen_string_literal: true

require "minitest/autorun"
require "set"
require_relative "../../lib/rpms_rpc/version"
require_relative "../../lib/rpms_rpc/capabilities"
require_relative "../../lib/rpms_rpc/mock_client"

class RpmsRpc::CapabilitiesTest < Minitest::Test
  User = Struct.new(:user_type, :security_keys, keyword_init: true)

  def setup
    RpmsRpc::Capabilities.reset_deprecation_warnings!
  end

  def teardown
    RpmsRpc.reset!
  end

  # The seven checks below test names that are not security keys on the
  # pinned build (#314). They are deprecated, not removed (ADR 0010; removal
  # is #359): behaviour is unchanged, and each warns once per process.
  DEPRECATED = {
    can_approve_chs?: %w[PRCFA\ SUPERVISOR BPRC\ MANAGER],
    can_process_chs?: %w[PRCFA\ TECH PRCFA\ SUPERVISOR],
    can_manage_chs?: %w[PRCFA\ SUPERVISOR BGOZ\ CHS\ CLERK],
    can_manage_consults?: %w[GMRC\ MGR],
    can_verify_eligibility?: %w[APCL\ VERIFY],
    can_access_behavioral_health?: %w[BGMH\ PROVIDER],
    can_access_dental?: %w[DENTP\ PROVIDER]
  }.freeze

  def test_each_deprecated_check_warns_once_naming_its_keys_and_the_replacement
    user = User.new(user_type: "clerk", security_keys: [])
    DEPRECATED.each do |check, key_names|
      _, err = capture_io { RpmsRpc::Capabilities.public_send(check, user) }
      assert_match(/\[rpms_rpc\] DEPRECATED: RpmsRpc::Capabilities\.#{Regexp.escape(check.to_s)} /, err)
      key_names.each { |k| assert_includes err, k, "#{check} must name #{k}" }
      assert_includes err, "not a security key on the pinned build"
      assert_includes err, "#318"
      assert_includes err, "ADR 0010"
      assert_includes err, "#359"

      _, again = capture_io { RpmsRpc::Capabilities.public_send(check, user) }
      assert_empty again, "#{check} warns once per process, not on every call"
    end
  end

  def test_deprecated_checks_answer_as_before
    held = User.new(user_type: "clerk", security_keys: %i[prc_supervisor prc_tech consult_manager eligibility_verify bh_provider dental_provider])
    none = User.new(user_type: "clerk", security_keys: [])
    capture_io do
      DEPRECATED.each_key do |check|
        assert RpmsRpc::Capabilities.public_send(check, held), "#{check} with its symbol"
        refute RpmsRpc::Capabilities.public_send(check, none), "#{check} without"
      end
    end
  end

  def test_capabilities_for_does_not_warn
    user = User.new(user_type: "case_manager", security_keys: %i[prc_supervisor bh_provider])
    assert_output("", "") { RpmsRpc::Capabilities.capabilities_for(user) }
  end

  def test_can_approve_chs_with_supervisor_key
    user = User.new(user_type: "case_manager", security_keys: [ :prc_supervisor ])
    capture_io { assert RpmsRpc::Capabilities.can_approve_chs?(user) }
  end

  def test_can_approve_chs_with_manager_key
    user = User.new(user_type: "case_manager", security_keys: [ :prc_manager ])
    capture_io { assert RpmsRpc::Capabilities.can_approve_chs?(user) }
  end

  def test_cannot_approve_chs_without_keys
    user = User.new(user_type: "clerk", security_keys: [])
    capture_io { refute RpmsRpc::Capabilities.can_approve_chs?(user) }
  end

  def test_can_process_chs
    user = User.new(user_type: "clerk", security_keys: [ :prc_tech ])
    capture_io { assert RpmsRpc::Capabilities.can_process_chs?(user) }
  end

  def test_can_manage_consults
    user = User.new(user_type: "nurse", security_keys: [ :consult_manager ])
    capture_io { assert RpmsRpc::Capabilities.can_manage_consults?(user) }
  end

  def test_cannot_manage_consults_without_key
    user = User.new(user_type: "nurse", security_keys: [])
    capture_io { refute RpmsRpc::Capabilities.can_manage_consults?(user) }
  end

  def test_can_access_behavioral_health
    user = User.new(user_type: "provider", security_keys: [ :bh_provider ])
    capture_io { assert RpmsRpc::Capabilities.can_access_behavioral_health?(user) }
  end

  def test_can_access_dental
    user = User.new(user_type: "provider", security_keys: [ :dental_supervisor ])
    capture_io { assert RpmsRpc::Capabilities.can_access_dental?(user) }
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
end
