# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../lib/rpms_rpc/user_roles"

# A role comes from security keys and nothing else. No sign-on reply carries a
# user class: VALIDAV^XUSRB answers DUZ/XUM/VCCH/message/0/message-count
# (XUSRB.m:9-11, :40, :85-87) and USERINFO^XUSRB2 answers DUZ, name, standard
# name, division, title, service/section, language and DTIME (XUSRB2.m:25-35).
# The one "user class" CPRS itself reports — USRCLS, piece 3 of ORWU USERINFO —
# is DERIVED FROM KEYS on the server (ORWU.m:19: ORES=3, ORELSE=2, OREMAS=1,
# else 0), which is the precedence resolve follows.
class RpmsRpc::UserRolesTest < Minitest::Test
  def test_resolve_provider_from_the_ores_key
    assert_equal "provider", RpmsRpc::UserRoles.resolve(security_keys: [ :ores ])
    assert_equal "provider", RpmsRpc::UserRoles.resolve(security_keys: [ :provider, :ores ])
  end

  def test_resolve_nurse_from_the_orelse_key
    assert_equal "nurse", RpmsRpc::UserRoles.resolve(security_keys: [ :orelse ])
  end

  def test_resolve_clerk_from_the_oremas_key
    assert_equal "clerk", RpmsRpc::UserRoles.resolve(security_keys: [ :oremas ])
  end

  def test_resolve_follows_orwu_usrclass_precedence_when_several_keys_are_held
    # ORWU.m:19 tests ORES first, then ORELSE, then OREMAS.
    assert_equal "provider", RpmsRpc::UserRoles.resolve(security_keys: [ :oremas, :orelse, :ores ])
    assert_equal "nurse", RpmsRpc::UserRoles.resolve(security_keys: [ :oremas, :orelse ])
  end

  def test_resolve_case_manager_from_security_key_elevation
    # prc_supervisor / prc_manager elevate above whatever the order keys yield.
    assert_equal "case_manager", RpmsRpc::UserRoles.resolve(security_keys: [ :ores, :prc_supervisor ])
    assert_equal "case_manager", RpmsRpc::UserRoles.resolve(security_keys: [ :orelse, :prc_manager ])
    assert_equal "case_manager", RpmsRpc::UserRoles.resolve(security_keys: [ :prc_manager ])
  end

  def test_resolve_defaults_to_user_without_a_role_bearing_key
    assert_equal "user", RpmsRpc::UserRoles.resolve(security_keys: [])
    assert_equal "user", RpmsRpc::UserRoles.resolve(security_keys: [ :cprs_gui_chart ])
    # PROVIDER alone is the file-200 provider flag (ORWU.m:21), not order authority.
    assert_equal "user", RpmsRpc::UserRoles.resolve(security_keys: [ :provider ])
  end

  def test_resolve_takes_no_user_class
    # The old `user_class:` input read av_code line 5, which is VALIDAV's
    # post-sign-on message count (#236). There is nothing to pass.
    assert_raises(ArgumentError) { RpmsRpc::UserRoles.resolve(user_class: "3", security_keys: []) }
  end

  def test_the_class_code_vocabulary_is_gone
    refute RpmsRpc::UserRoles.respond_to?(:for_class)
    refute RpmsRpc::UserRoles.respond_to?(:class_for)
    refute RpmsRpc::UserRoles.respond_to?(:mock_av_code)
    refute RpmsRpc::UserRoles.const_defined?(:USER_CLASS_MAP)
  end
end
