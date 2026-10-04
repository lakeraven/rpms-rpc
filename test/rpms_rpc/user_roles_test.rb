# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../lib/rpms_rpc/user_roles"

class RpmsRpc::UserRolesTest < Minitest::Test
  def test_for_class_maps_known_classes
    assert_equal "provider", RpmsRpc::UserRoles.for_class("3")
    assert_equal "nurse", RpmsRpc::UserRoles.for_class("4")
    assert_equal "clerk", RpmsRpc::UserRoles.for_class("5")
    assert_equal "admin", RpmsRpc::UserRoles.for_class("1")
  end

  def test_for_class_defaults_to_user
    assert_equal "user", RpmsRpc::UserRoles.for_class("99")
    assert_equal "user", RpmsRpc::UserRoles.for_class("")
  end

  def test_for_class_accepts_integer
    assert_equal "nurse", RpmsRpc::UserRoles.for_class(4)
  end

  def test_resolve_provider_from_av_code_class
    assert_equal "provider", RpmsRpc::UserRoles.resolve(
      user_class: "3", security_keys: []
    )
  end

  def test_resolve_case_manager_from_security_key_elevation
    # prc_supervisor elevates beyond whatever user_class would yield.
    assert_equal "case_manager", RpmsRpc::UserRoles.resolve(
      user_class: "3", security_keys: [ :prc_supervisor ]
    )
    assert_equal "case_manager", RpmsRpc::UserRoles.resolve(
      user_class: "4", security_keys: [ :prc_manager ]
    )
  end

  def test_resolve_nurse_from_class
    assert_equal "nurse", RpmsRpc::UserRoles.resolve(
      user_class: "4", security_keys: []
    )
  end

  def test_resolve_defaults_to_user_when_class_unknown_blank_or_nil
    assert_equal "user", RpmsRpc::UserRoles.resolve(
      user_class: nil, security_keys: []
    )
    assert_equal "user", RpmsRpc::UserRoles.resolve(
      user_class: "", security_keys: []
    )
    assert_equal "user", RpmsRpc::UserRoles.resolve(
      user_class: "99", security_keys: []
    )
  end
end
