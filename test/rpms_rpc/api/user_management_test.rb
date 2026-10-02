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
    assert_equal %i[user_info practitioner], summary.keys
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
end
