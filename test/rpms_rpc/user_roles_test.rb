# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../lib/rpms_rpc/user_roles"

class RpmsRpc::UserRolesTest < Minitest::Test
  def setup
    RpmsRpc::UserRoles.reset_deprecation_warnings!
  end

  def deprecated_lines(io)
    io.lines.grep(/DEPRECATED/)
  end

  def assert_deprecation_warned_from_this_test(err)
    base = File.basename(__FILE__)
    deprecated_lines(err).each do |line|
      assert_match(/#{Regexp.escape(base)}:\d+: warning:/, line,
                   "warning must attribute to caller in #{base}, not lib: #{line}")
      refute_match(/capabilities\.rb:\d+: warning:/, line)
      refute_match(/user_roles\.rb:\d+: warning:/, line)
    end
  end

  def assert_deprecated_api_warns_once(method)
    _, err = capture_io { yield }
    assert_equal 1, deprecated_lines(err).size, "#{method} emits exactly one DEPRECATED line"
    line = deprecated_lines(err).first
    assert_deprecation_warned_from_this_test(err)
    assert_match(/\[rpms_rpc\] DEPRECATED: RpmsRpc::UserRoles\.#{Regexp.escape(method.to_s)}/, line)
    assert_includes line, "#318"
    assert_includes line, "ADR 0010"
    assert_includes line, "#359"

    _, again = capture_io { yield }
    assert_empty deprecated_lines(again), "#{method} warns once per process, not on every call"
  end

  def test_for_class_warns_once_naming_replacement
    assert_deprecated_api_warns_once(:for_class) { RpmsRpc::UserRoles.for_class("3") }
  end

  def test_class_for_warns_once_naming_replacement
    assert_deprecated_api_warns_once(:class_for) { RpmsRpc::UserRoles.class_for("provider") }
  end

  def test_mock_av_code_warns_once_naming_replacement
    assert_deprecated_api_warns_once(:mock_av_code) do
      RpmsRpc::UserRoles.mock_av_code(duz: 1, role: "provider")
    end
  end

  def test_resolve_warns_once_naming_replacement
    assert_deprecated_api_warns_once(:resolve) do
      RpmsRpc::UserRoles.resolve(user_class: "3", security_keys: [])
    end
  end

  def test_each_user_roles_method_warns_once_independently
    RpmsRpc::UserRoles.reset_deprecation_warnings!

    [
      [ :for_class, -> { RpmsRpc::UserRoles.for_class("3") } ],
      [ :class_for, -> { RpmsRpc::UserRoles.class_for("provider") } ],
      [ :mock_av_code, -> { RpmsRpc::UserRoles.mock_av_code(duz: 1, role: "provider") } ],
      [ :resolve, -> { RpmsRpc::UserRoles.resolve(user_class: "3", security_keys: []) } ]
    ].each do |method, call|
      _, err = capture_io { call.call }
      assert_deprecation_warned_from_this_test(err)
      assert_equal 1, deprecated_lines(err).size, "#{method} emits exactly one DEPRECATED line on first call"
      assert_match(/\[rpms_rpc\] DEPRECATED: RpmsRpc::UserRoles\.#{Regexp.escape(method.to_s)}/,
                   deprecated_lines(err).first)
    end

    _, again = capture_io do
      RpmsRpc::UserRoles.for_class("3")
      RpmsRpc::UserRoles.class_for("provider")
      RpmsRpc::UserRoles.mock_av_code(duz: 1, role: "provider")
      RpmsRpc::UserRoles.resolve(user_class: "3", security_keys: [])
    end
    assert_empty deprecated_lines(again), "each method warns once per process, not on every call"
  end

  def test_mock_av_code_warns_only_once_when_class_for_called_internally
    RpmsRpc::UserRoles.reset_deprecation_warnings!

    _, err = capture_io { RpmsRpc::UserRoles.mock_av_code(duz: 42, role: "nurse") }
    assert_deprecation_warned_from_this_test(err)
    assert_equal 1, deprecated_lines(err).size
    assert_match(/\[rpms_rpc\] DEPRECATED: RpmsRpc::UserRoles\.mock_av_code/, deprecated_lines(err).first)
    refute_match(/class_for/, err)
  end

  def test_resolve_warns_only_once_when_for_class_called_internally
    RpmsRpc::UserRoles.reset_deprecation_warnings!

    _, err = capture_io { RpmsRpc::UserRoles.resolve(user_class: "4", security_keys: []) }
    assert_deprecation_warned_from_this_test(err)
    assert_equal 1, deprecated_lines(err).size
    assert_match(/\[rpms_rpc\] DEPRECATED: RpmsRpc::UserRoles\.resolve/, deprecated_lines(err).first)
    refute_match(/for_class/, err)
  end

  def test_deprecated_methods_return_unchanged_results
    capture_io do
      assert_equal "provider", RpmsRpc::UserRoles.for_class("3")
      assert_equal "3", RpmsRpc::UserRoles.class_for("provider")
      assert_equal({ duz: 9, error_code: 0, verify_needs_change: 0, message: "", user_class: 3 },
                   RpmsRpc::UserRoles.mock_av_code(duz: 9, role: "provider"))
      assert_equal "nurse", RpmsRpc::UserRoles.resolve(user_class: "4", security_keys: [])
      assert_equal "case_manager", RpmsRpc::UserRoles.resolve(
        user_class: "3", security_keys: [ :prc_supervisor ]
      )
    end
  end

  def test_for_class_maps_known_classes
    capture_io do
      assert_equal "provider", RpmsRpc::UserRoles.for_class("3")
      assert_equal "nurse", RpmsRpc::UserRoles.for_class("4")
      assert_equal "clerk", RpmsRpc::UserRoles.for_class("5")
      assert_equal "admin", RpmsRpc::UserRoles.for_class("1")
    end
  end

  def test_for_class_defaults_to_user
    capture_io do
      assert_equal "user", RpmsRpc::UserRoles.for_class("99")
      assert_equal "user", RpmsRpc::UserRoles.for_class("")
    end
  end

  def test_roles_without_class_number_fail_closed_to_user_class_zero
    capture_io do
      assert_nil RpmsRpc::UserRoles.class_for("case_manager")
      assert_nil RpmsRpc::UserRoles.class_for("nobody")
      assert_nil RpmsRpc::UserRoles.class_for(nil)

      assert_equal 0, RpmsRpc::UserRoles.mock_av_code(duz: 7, role: "case_manager")[:user_class]
      assert_equal 0, RpmsRpc::UserRoles.mock_av_code(duz: 7, role: "nobody")[:user_class]

      assert_equal "user", RpmsRpc::UserRoles.for_class(0)
    end
  end

  def test_for_class_accepts_integer
    capture_io do
      assert_equal "nurse", RpmsRpc::UserRoles.for_class(4)
    end
  end

  def test_resolve_provider_from_av_code_class
    capture_io do
      assert_equal "provider", RpmsRpc::UserRoles.resolve(
        user_class: "3", security_keys: []
      )
    end
  end

  def test_resolve_case_manager_from_security_key_elevation
    capture_io do
      # prc_supervisor elevates beyond whatever user_class would yield.
      assert_equal "case_manager", RpmsRpc::UserRoles.resolve(
        user_class: "3", security_keys: [ :prc_supervisor ]
      )
      assert_equal "case_manager", RpmsRpc::UserRoles.resolve(
        user_class: "4", security_keys: [ :prc_manager ]
      )
    end
  end

  def test_resolve_nurse_from_class
    capture_io do
      assert_equal "nurse", RpmsRpc::UserRoles.resolve(
        user_class: "4", security_keys: []
      )
    end
  end

  def test_resolve_defaults_to_user_when_class_unknown_blank_or_nil
    capture_io do
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

  def test_class_for_accepts_symbol_role
    capture_io do
      assert_equal "3", RpmsRpc::UserRoles.class_for(:provider)
    end
  end

  def test_mock_av_code_accepts_symbol_role_and_coerces_string_duz
    capture_io do
      assert_equal 3, RpmsRpc::UserRoles.mock_av_code(duz: 1, role: :provider)[:user_class]
      assert_equal 9, RpmsRpc::UserRoles.mock_av_code(duz: "9", role: "provider")[:duz]
    end
  end

  def test_resolve_does_not_elevate_on_string_supervisor_keys
    capture_io do
      assert_equal "provider", RpmsRpc::UserRoles.resolve(
        user_class: "3", security_keys: %w[prc_supervisor]
      )
      assert_equal "provider", RpmsRpc::UserRoles.resolve(
        user_class: "3", security_keys: %w[prc_manager]
      )
    end
  end
end
