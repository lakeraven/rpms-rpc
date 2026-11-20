# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/practitioner"
require_relative "../captured_replies"

# Practitioner.find answers only for the signed-on user: it reads ORWU
# USERINFO, the reply a fresh rpms-ydb container sent MANAGER,SYSTEM, DUZ 4
# (test/fixtures/captured_replies/user-management.yml), replayed through
# CiaClient. Practitioner.search is test/rpms_rpc/api/practitioner_search_key_test.rb
# and Referral.find is test/rpms_rpc/gateways/referral_lifecycle_test.rb.
class ClinicalTest < Minitest::Test
  def setup
    @client = CapturedReplies::ReplayCiaClient.new(
      "ORWU USERINFO" => [ CapturedReplies.raw("user-management", "userinfo") ]
    )
    RpmsRpc.configure { |cfg| cfg.client = @client }
  end

  def teardown
    RpmsRpc.reset!
  end

  def test_practitioner_find_returns_the_session_user_when_the_ien_matches
    result = RpmsRpc::Practitioner.find(4)

    assert_equal [ 4, 4, "MANAGER,SYSTEM", 3 ], result.values_at(:duz, :ien, :name, :user_class)
    assert_equal [ [ "ORWU USERINFO", [] ] ], @client.calls.map { |c| [ c[:rpc], c[:params] ] }
  end

  def test_practitioner_find_is_nil_for_another_user
    assert_nil RpmsRpc::Practitioner.find(99_999)
  end

  def test_practitioner_find_sends_nothing_for_no_ien
    assert_nil RpmsRpc::Practitioner.find(0)
    assert_empty @client.calls
  end
end
