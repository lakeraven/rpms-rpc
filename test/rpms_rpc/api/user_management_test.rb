# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/user_management"

class UserManagementTest < Minitest::Test
  DUZ = 301

  def setup
    RpmsRpc.mock! do |m|
      # ORWU NEWPERS — same RPC as practitioner search, but File 200 user shape.
      # Format per line: DUZ^NAME^TITLE
      m.seed_collection(:user_management_user_list, [
        { duz: DUZ, name: "PROVIDER,TEST", title: "MD" },
        { duz: 405, name: "NURSE,TEST", title: "RN" }
      ], filter_field: :name)

      m.seed_lines(:user_info, "", {
        duz: DUZ,
        name: "PROVIDER,TEST",
        display_name: "PROVIDER,TEST",
        current_site: "7819^DEMO IHS CLINIC^8904",
        user_class_ien: 30
      })

      m.seed(:practitioner_info, "", {
        duz: DUZ, name: "PROVIDER,TEST", user_class: 3,
        kernel_domain: "DEMO.IHS.GOV", site_ien: 8904
      })

      m.seed_keyed_collection(:user_keys, DUZ.to_s, [
        { key_name: "XUPROGMODE" },
        { key_name: "PROVIDER" },
        { key_name: "" }
      ])

      m.seed_collection(:key_list, [
        { ien: 1, name: "XUPROGMODE" },
        { ien: 2, name: "PROVIDER" }
      ])

      m.seed(:key_grant, DUZ.to_s, { success: true, message: "Key granted" })
      m.seed(:key_revoke, DUZ.to_s, { success: true, message: "Key revoked" })
      m.seed(:key_grant, "999", { success: false, message: "No such user" })
      m.seed(:key_revoke, "999", { success: false, message: "" })

      # Non-caret error response — gateway strips a leading "0" to surface
      # the raw error text. Seeded as raw text so it bypasses the field-based
      # format and exercises the first-line parsing path.
      m.seed_text(:key_grant,  "1234", "0No such key")
      m.seed_text(:key_revoke, "5678", "0Permission denied")
      # Non-caret success response — gateway treats any line starting with "1"
      # as success regardless of trailing text or caret.
      m.seed_text(:key_grant, "4321", "1OK")
    end
  end

  def teardown
    RpmsRpc.reset!
  end

  def test_search_returns_matching_users
    users = RpmsRpc::UserManagement.search("PRO")

    assert_equal 1, users.length
    assert_equal DUZ.to_s, users.first[:duz]
    assert_equal "PROVIDER,TEST", users.first[:name]
  end

  def test_search_returns_empty_for_blank_pattern
    assert_equal [], RpmsRpc::UserManagement.search(nil)
    assert_equal [], RpmsRpc::UserManagement.search("")
    assert_equal [], RpmsRpc::UserManagement.search("   ")
  end

  def test_find_returns_access_summary
    summary = RpmsRpc::UserManagement.find(DUZ)

    refute_nil summary
    assert_equal DUZ, summary[:user_info][:duz]
    assert_equal "PROVIDER,TEST", summary[:practitioner][:name]
    assert_equal %w[PROVIDER XUPROGMODE], summary[:security_keys]
  end

  def test_find_rejects_blank_zero_negative_and_nonnumeric_duz
    assert_nil RpmsRpc::UserManagement.find(nil)
    assert_nil RpmsRpc::UserManagement.find("")
    assert_nil RpmsRpc::UserManagement.find(0)
    assert_nil RpmsRpc::UserManagement.find(-1)
    assert_nil RpmsRpc::UserManagement.find("abc")
    assert_nil RpmsRpc::UserManagement.find("123abc")
  end

  def test_find_returns_nil_for_unknown_duz
    assert_nil RpmsRpc::UserManagement.find(999_998)
  end

  def test_find_returns_empty_security_keys_when_capability_unsupported
    RpmsRpc.client.seed_capability(:user_security_keys_list, supported: false)
    summary = RpmsRpc::UserManagement.find(DUZ)

    refute_nil summary
    assert_equal [], summary[:security_keys]
    assert_nil RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWU USERKEYS" }
  end

  def test_grant_key_calls_rpc_and_returns_success_message
    result = RpmsRpc::UserManagement.grant_key(DUZ, "PROVIDER")

    assert_equal true, result[:success]
    assert_equal "Key PROVIDER granted to DUZ #{DUZ}", result[:message]
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "XU KEY GRANT" }
    assert_equal [ DUZ.to_s, "PROVIDER" ], call[:params]
  end

  def test_revoke_key_calls_rpc_and_returns_success_message
    result = RpmsRpc::UserManagement.revoke_key(DUZ, "PROVIDER")

    assert_equal true, result[:success]
    assert_equal "Key PROVIDER revoked from DUZ #{DUZ}", result[:message]
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "XU KEY REVOKE" }
    assert_equal [ DUZ.to_s, "PROVIDER" ], call[:params]
  end

  def test_key_changes_reject_invalid_duz_and_blank_key
    assert_equal({ success: false, error: "Invalid DUZ" }, RpmsRpc::UserManagement.grant_key(0, "PROVIDER"))
    assert_equal({ success: false, error: "Invalid DUZ" }, RpmsRpc::UserManagement.revoke_key(-1, "PROVIDER"))
    assert_equal({ success: false, error: "Invalid DUZ" }, RpmsRpc::UserManagement.grant_key("123abc", "PROVIDER"))
    assert_equal({ success: false, error: "Key name required" }, RpmsRpc::UserManagement.grant_key(DUZ, " "))
  end

  def test_key_changes_return_rpc_errors_or_defaults
    assert_equal({ success: false, error: "No such user" }, RpmsRpc::UserManagement.grant_key(999, "PROVIDER"))
    assert_equal({ success: false, error: "Revoke failed" }, RpmsRpc::UserManagement.revoke_key(999, "PROVIDER"))
  end

  def test_key_changes_strip_bare_zero_prefix_from_non_caret_error_responses
    grant = RpmsRpc::UserManagement.grant_key(1234, "PROVIDER")
    assert_equal false,          grant[:success]
    assert_equal "No such key",  grant[:error]

    revoke = RpmsRpc::UserManagement.revoke_key(5678, "PROVIDER")
    assert_equal false,                revoke[:success]
    assert_equal "Permission denied",  revoke[:error]
  end

  def test_key_changes_accept_non_caret_success_responses
    result = RpmsRpc::UserManagement.grant_key(4321, "PROVIDER")
    assert_equal true, result[:success]
    assert_match(/granted/, result[:message])
  end

  def test_list_all_keys_returns_file_19_1_entries
    keys = RpmsRpc::UserManagement.list_all_keys

    assert_equal 2, keys.length
    assert_equal({ ien: 1, name: "XUPROGMODE" }, keys.first)
    assert_equal({ ien: 2, name: "PROVIDER" }, keys.last)
  end

  def test_list_all_keys_returns_empty_when_xu_key_admin_unsupported
    RpmsRpc.client.seed_capability(:xu_key_admin, supported: false)
    assert_equal [], RpmsRpc::UserManagement.list_all_keys
    assert_nil RpmsRpc.client.received_calls.find { |c| c[:rpc] == "XU KEY LIST" }
  end

  def test_grant_key_short_circuits_when_xu_key_admin_unsupported
    RpmsRpc.client.seed_capability(:xu_key_admin, supported: false)
    result = RpmsRpc::UserManagement.grant_key(DUZ, "PROVIDER")

    assert_equal false, result[:success]
    assert_match(/not available/i, result[:error].to_s)
    assert_nil RpmsRpc.client.received_calls.find { |c| c[:rpc] == "XU KEY GRANT" }
  end

  def test_revoke_key_short_circuits_when_xu_key_admin_unsupported
    RpmsRpc.client.seed_capability(:xu_key_admin, supported: false)
    result = RpmsRpc::UserManagement.revoke_key(DUZ, "PROVIDER")

    assert_equal false, result[:success]
    assert_match(/not available/i, result[:error].to_s)
    assert_nil RpmsRpc.client.received_calls.find { |c| c[:rpc] == "XU KEY REVOKE" }
  end
end
