# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/referral"
require_relative "../captured_replies"

# Referral.update with a diagnosis (rpms-rpc#915): UPDREFRL^BMCRPC2 takes
# the ICD code and its narrative as parameters 31 and 32 and files them
# through EDITRD^BMCRPC5. The replies are the build's
# (test/fixtures/captured_replies/referral-diagnosis.yml), recorded as the
# provider test role on bcer-9.0-20261124-60d39b6-ydb, the first release
# whose BMC GET REFERRAL reads a diagnosis back (openrpms#1271).
class ReferralDiagnosisTest < Minitest::Test
  SLUG = "referral-diagnosis"

  def teardown
    RpmsRpc.reset!
  end

  def replay(flow)
    @client = CapturedReplies::ReplayCiaClient.new(flow ? CapturedReplies.flow_script(SLUG, flow) : {})
    RpmsRpc.configure { |cfg| cfg.client = @client }
  end

  def sent = @client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params] ] }

  def test_update_sends_the_code_and_narrative_as_parameters_31_and_32
    replay("update")

    result = RpmsRpc::Referral.update("1", diagnosis_code: "E11.9", diagnosis_narrative: "Type 2 diabetes mellitus")

    assert result[:success], result.inspect
    assert_equal CapturedReplies.flow_calls(SLUG, "update"), sent
    params = sent.find { |rpc, _| rpc == "BMC UPDATE REFERRAL" }.last
    assert_equal [ "E11.9", "Type 2 diabetes mellitus", "" ], params[30, 3]
  end

  def test_find_reads_the_diagnosis_back
    replay("find")

    diagnoses = RpmsRpc::Referral.find("1")[:diagnoses]

    assert_equal 1, diagnoses.size
    assert_equal [ "E11.9", "Type 2 diabetes mellitus", "PROVISIONAL", "PRIMARY" ],
                 diagnoses.first.values_at(:icd_code, :narrative, :type, :primary_secondary)
  end

  # EDITRD deletes the referral's diagnoses before it looks the code up, and
  # UPDREFRL answers "~`1" whatever it finds, so a code not in #80 is refused
  # before BMC UPDATE REFERRAL is sent.
  def test_an_icd_code_not_on_file_is_refused_before_the_update_is_sent
    replay("unknown_code")

    result = RpmsRpc::Referral.update("1", diagnosis_code: "ZZZ.99", diagnosis_narrative: "No such code")

    refute result[:success]
    assert_match(/ICD DIAGNOSIS ZZZ\.99 is not on file/, result[:message])
    assert_equal CapturedReplies.flow_calls(SLUG, "unknown_code"), sent
    refute(sent.any? { |rpc, _| rpc == "BMC UPDATE REFERRAL" })
  end

  def test_a_code_without_its_narrative_is_refused_before_the_wire
    replay(nil)

    assert_raises(ArgumentError) { RpmsRpc::Referral.update("1", diagnosis_code: "E11.9") }
    assert_raises(ArgumentError) { RpmsRpc::Referral.update("1", diagnosis_narrative: "Type 2 diabetes mellitus") }
    assert_empty sent
  end
end
