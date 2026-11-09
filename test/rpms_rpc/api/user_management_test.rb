# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/user_management"
require_relative "../captured_replies"

# UserManagement reads the ORWU NEWPERS, XUS GET USER INFO and ORWU USERINFO
# replies a fresh rpms-ydb container sent to its operator, MANAGER,SYSTEM,
# DUZ 4 (test/fixtures/captured_replies/user-management.yml), replayed
# through CiaClient.
class UserManagementTest < Minitest::Test
  SLUG = "user-management"
  DUZ = 4

  def teardown
    RpmsRpc.reset!
  end

  def replay(script)
    client = CapturedReplies::ReplayCiaClient.new(script)
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def capture(name) = CapturedReplies.raw(SLUG, name)
  def find_script = { "XUS GET USER INFO" => [ capture("user_info") ], "ORWU USERINFO" => [ capture("userinfo") ] }

  def test_search_returns_the_users_after_the_pattern
    client = replay("ORWU NEWPERS" => [ capture("newpers_pro") ])

    users = RpmsRpc::UserManagement.search("PRO")

    assert_equal %w[209 204 206 207 210 205 208 200], users.map { |u| u[:duz] }
    assert_equal({ duz: "206", name: "Profile,Md" }, users.find { |u| u[:duz] == "206" }.slice(:duz, :name))
    assert_equal [ "PRO", "1" ], client.calls.first[:params]
  end

  def test_search_returns_empty_for_blank_pattern_without_a_call
    client = replay({})

    assert_equal [], RpmsRpc::UserManagement.search(nil)
    assert_equal [], RpmsRpc::UserManagement.search("")
    assert_equal [], RpmsRpc::UserManagement.search("   ")
    assert_empty client.calls
  end

  def test_find_returns_the_signed_on_users_access_summary
    replay(find_script)

    summary = RpmsRpc::UserManagement.find(DUZ)

    assert_equal %i[user_info practitioner], summary.keys
    assert_equal DUZ, summary[:user_info][:duz]
    assert_equal "MANAGER,SYSTEM", summary[:user_info][:name]
    assert_equal "7819^DEMO IHS CLINIC^8904", summary[:user_info][:current_site]
    assert_equal DUZ, summary[:practitioner][:duz]
    assert_equal "MANAGER,SYSTEM", summary[:practitioner][:name]
    assert_equal "DEMO.IHS.GOV", summary[:practitioner][:kernel_domain]
    assert_equal 8904, summary[:practitioner][:site_ien]
  end

  def test_find_rejects_blank_zero_negative_and_nonnumeric_duz_without_a_call
    client = replay({})

    [ nil, "", 0, -1, "abc", "123abc" ].each { |duz| assert_nil RpmsRpc::UserManagement.find(duz) }
    assert_empty client.calls
  end

  # XUS GET USER INFO answers for the signed-on user only, so a DUZ that is
  # not that user is nil, and USERINFO is never asked.
  def test_find_returns_nil_for_a_duz_that_is_not_the_signed_on_user
    client = replay(find_script)

    assert_nil RpmsRpc::UserManagement.find(206)
    assert_equal [ "XUS GET USER INFO" ], client.rpcs_called
  end
end
