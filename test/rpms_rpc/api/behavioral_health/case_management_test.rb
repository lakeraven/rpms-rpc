# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/behavioral_health/case_management"
require_relative "../../captured_replies"

# RpmsRpc::BehavioralHealth::CaseManagement on the AMHG replies a fresh
# rpms-ydb container sent (test/fixtures/captured_replies/amhg-groups-cases.yml),
# replayed through CiaClient's GLOBAL ARRAY read, per ADR 0009: the parameter
# each read sends, and the empty and not-on-file answers. A fresh container has
# no BH case or community activity, so a filled row is not pinned here
# (rpms-rpc#622, #673).
class BehavioralHealthCaseManagementTest < Minitest::Test
  C = RpmsRpc::BehavioralHealth::CaseManagement
  SLUG = "amhg-groups-cases"
  NOT_ON_FILE = "999999"

  def teardown
    RpmsRpc.reset!
  end

  def capture(name) = CapturedReplies.file(SLUG).fetch("captures").find { |c| c["name"] == name }

  def replay(name)
    client = CapturedReplies::ReplayCiaClient.new(capture(name).fetch("rpc") => [ CapturedReplies.raw(SLUG, name) ])
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def sent(client) = client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| c[:params] }

  def test_case_dates_with_none_on_file_is_empty_and_sends_from_to_dfn
    client = replay("case_dates_none")

    assert_empty C.case_dates("4", from: "3000101", to: "3271231")
    assert_equal [ capture("case_dates_none")["inputs"] ], sent(client)
  end

  # CM^AMHGDCM always writes one row (AMHGDCM.m:38-40).
  def test_case_management_for_an_ien_not_on_file_is_a_row_of_blanks
    client = replay("case_management_not_on_file")

    record = C.case_management(NOT_ON_FILE)
    assert_equal NOT_ON_FILE, record[:ien]
    assert_empty record.except(:ien).values.compact
    assert_equal [ [ NOT_ON_FILE ] ], sent(client)
  end

  def test_community_activities_with_none_on_file_is_empty_and_sends_from_to_provider
    client = replay("community_activities_none")

    assert_empty C.community_activities("4", from: "3000101", to: "3271231")
    assert_equal [ capture("community_activities_none")["inputs"] ], sent(client)
  end

  def test_community_activity_for_an_ien_not_on_file_is_a_row_of_blanks
    replay("community_activity_not_on_file")

    activity = C.community_activity(NOT_ON_FILE)
    assert_equal NOT_ON_FILE, activity[:ien]
    assert_equal "1700,,,12,0", activity[:date], "what the build sends for an empty date"
    assert_empty activity.except(:ien, :date).values.compact
  end
end
