# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/coverage"

# A private policy with no end date is filed once, and reported as filed
# (rpms-rpc#688). The gem used to leave both end-date fields out; UPD^AGGUPPVT
# filed the policy, then UPOL^AGGUPPVT died on the bare AGGPHEED, the reply
# stopped after its header, and the gem reported a failure a retry would
# answer with a second policy. It now sends them blank.
#
# Runs as the registration persona (PROFILE,REG): every call is in AGGRPC.
class CoveragePrivateNoEndDateLiveTest < LiveSpec::Test
  writes!

  DFN = 990_050 # ASHGROVE,SAM on the pinned build; unused by other live specs

  def test_a_policy_with_no_end_date_is_reported_filed_and_is_on_file_once
    insurer = billable_private_insurer!
    before = policies
    record = nil

    added = RpmsRpc::Coverage.add_private_insurance(DFN, insurer_ien: insurer, policy_holder: "ASHGROVE,SAM",
                                                         member_number: "ZZ6880001", effective_on: "11/01/2026",
                                                         client: client)
    record = added && added[:record_ien]
    assert_equal true, added && added[:success], "add_private_insurance reported #{added.inspect}"
    refute_empty record.to_s, "no record IEN: #{added.inspect}"

    after = policies
    assert_equal before.size + 1, after.size, "one policy filed: #{after.inspect}"
    filed = after.find { |p| p[:record_ien].to_s == record.to_s }
    refute_nil filed, "the record the gem reported (#{record}) is not on file: #{after.inspect}"
    assert_equal "ZZ6880001", filed[:number]
    assert_equal Date.new(2026, 11, 1), filed[:starts_on]
    assert_nil filed[:ends_on]
  ensure
    cleanup!(record, before)
  end

  private

  # Delete what this test filed: the record the gem reported or, when the reply
  # named none (the #688 regression), every policy that was not on file before.
  def cleanup!(record, before)
    known = Array(before).map { |p| p[:record_ien].to_s }
    ids = record.to_s.empty? ? policies.map { |p| p[:record_ien].to_s } - known : [ record.to_s ]
    ids.each { |id| RpmsRpc::Coverage.delete_private_insurance(DFN, record_ien: id, client: client) }
  rescue StandardError, Minitest::Assertion
    # best-effort teardown when an earlier assertion failed
  end

  def policies
    found = RpmsRpc::Coverage.on_file(DFN, client: client)
    flunk "on_file gave no answer for #{DFN}" if found.nil?
    found[:private]
  end

  def billable_private_insurer!
    insurers = RpmsRpc::Coverage.insurers(client: client)
    flunk "AGG GET INSURANCE DATA gave no answer" if insurers.nil?
    found = insurers.find { |row| row[:status] == "BILLABLE" } || insurers.first
    flunk "the build lists no insurer" unless found
    found[:ien]
  end
end
