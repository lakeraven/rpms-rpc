# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/coverage"

# A private policy naming an insurer that is not on file is refused before
# anything is written, and the patient's coverage still reads (rpms-rpc#691).
# UPD^AGGUPPVT files the insurer pointer as given, and RET^AGGINSUR then reads
# ^AUTNINS(IIEN,0) bare, so the patient's Private Insurance window died on
# every read and on_file timed out. The gem now checks AG's insurer list first.
#
# Runs as the registration persona (PROFILE,REG): every call is in AGGRPC.
class CoveragePrivateUnknownInsurerLiveTest < LiveSpec::Test
  writes!

  DFN = 990_051 # unused by other live specs

  def test_an_insurer_ag_does_not_list_is_refused_and_coverage_still_reads
    insurers = RpmsRpc::Coverage.insurers(client: client)
    flunk "AGG GET INSURANCE DATA gave no answer" if insurers.nil?
    unknown = (insurers.map { |row| row[:ien].to_i }.max.to_i + 900_000).to_s
    before = policies

    got = RpmsRpc::Coverage.add_private_insurance(DFN, insurer_ien: unknown, policy_holder: "LIVE,UNKNOWN",
                                                       member_number: "ZZ6910001", effective_on: "11/01/2026",
                                                       client: client)

    assert_equal({ success: false, error: :insurer_not_on_file,
                   message: "insurer #{unknown} is not on file (AGG GET INSURANCE DATA)" }, got)
    assert_equal before, policies, "nothing filed, and the Private Insurance window still answers"
  ensure
    cleanup!(got)
  end

  private

  # Delete the policy a regression filed, by the record IEN the add reported:
  # delete_private_insurance goes through FileMan, not the AG window a
  # dangling insurer breaks.
  def cleanup!(got)
    record = got.is_a?(Hash) && got[:success] ? got[:record_ien].to_s : ""
    return if record.empty?

    RpmsRpc::Coverage.delete_private_insurance(DFN, record_ien: record, client: client)
  rescue StandardError, Minitest::Assertion
    # best-effort teardown when an earlier assertion failed
  end

  def policies
    found = RpmsRpc::Coverage.on_file(DFN, client: client)
    flunk "on_file gave no answer for #{DFN}" if found.nil?
    found[:private]
  end
end
