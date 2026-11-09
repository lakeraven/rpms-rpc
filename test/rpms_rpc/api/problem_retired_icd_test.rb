# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/problem"
require_relative "../captured_replies"

# Problem.for_patient reads the ORQQPL LIST replies a fresh rpms-ydb container
# sent after a problem with retired ICD-9-CM 203.1 was filed for demo patient
# 4 (test/fixtures/captured_replies/orqqpl-list-retired-icd.yml), replayed
# through CiaClient. rpms-rpc#532: a retired code is kept and flagged; error
# text in piece 4 is never a code, on either branch.
class ProblemRetiredIcdTest < Minitest::Test
  SLUG = "orqqpl-list-retired-icd"

  def teardown
    RpmsRpc.reset!
  end

  def replay(name)
    client = CapturedReplies::ReplayCiaClient.new("ORQQPL LIST" => [ CapturedReplies.raw(SLUG, name) ])
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def test_a_retired_code_is_kept_and_flagged_inactive
    replay("retired_code")

    retired = RpmsRpc::Problem.for_patient("4").find { |row| row[:description].to_s.include?("Retired code demo") }
    refute_nil retired, "the capture holds the filed retired-code problem"
    assert_equal "203.1", retired[:icd_code], "a retired code is the patient's recorded diagnosis: keep it"
    assert_equal true, retired[:inactive_icd]
    assert_nil retired[:transcribed], "piece 9's '#' is the branch marker, not a transcribed flag"
  end

  def test_error_text_on_the_inactive_branch_is_never_a_code
    replay("retired_code")

    errors = RpmsRpc::Problem.for_patient("4").reject { |row| row[:description].to_s.include?("Retired code demo") }
    assert_equal 4, errors.size, "the four seeded problems answer $$ICDDX error text in piece 4"
    errors.each do |row|
      assert_nil row[:icd_code], "#{row[:description].inspect}: error text is not an icd_code"
      assert_equal true, row[:inactive_icd]
    end
  end

  def test_the_no_problems_sentinel_is_no_rows
    client = replay("no_problems")

    assert_equal [], RpmsRpc::Problem.for_patient("999999")
    assert_equal [ [ "999999", "" ] ], client.calls.map { |c| c[:params] }
  end
end
