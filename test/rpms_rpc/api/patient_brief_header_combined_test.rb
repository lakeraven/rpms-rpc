# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/patient"

# brief_header carries both the #523 designated-primary GETBDP row and the
# #553 ORWPT CWAD read under OR CPRS GUI CHART. Synthetic seeds only.
class PatientBriefHeaderCombinedTest < Minitest::Test
  DFN = "42"
  CHART_CONTEXT = "OR CPRS GUI CHART"
  CALLER_CONTEXT = "CIAV VUECENTRIC"

  def setup
    RpmsRpc.mock!
  end

  def teardown
    RpmsRpc.reset!
  end

  # Proves the designated-primary row wins over PTINFO while the CWAD read is
  # still scoped to OR CPRS GUI CHART, GETBDP stays on the caller's context,
  # and the caller's option is restored.
  def test_designated_primary_row_and_scoped_cwad_both_apply
    mock = RpmsRpc.client
    mock.create_context(CALLER_CONTEXT)
    caller_context = mock.current_context
    binds_after_setup = mock.context_binds.length
    mock.seed(:patient_ptinfo, DFN,
              { name: "SYNTH,PATIENT", sex: "F", dob_raw: "3010101", mrn: "MRN01", primary_provider: "PTINFO,PROVIDER" })
    mock.seed_raw_lines(:patient_designated_provider, DFN,
                        [ "AAA CATEGORY^OTHER,PROVIDER^101^PHYSICIAN^3250101",
                          "DESIGNATED PRIMARY PROVIDER^DESIGNATED,PROVIDER^102^PHYSICIAN^3250101" ])
    mock.seed_scalar(:patient_cwad, DFN, "WA")

    header = RpmsRpc::Patient.brief_header(DFN)

    assert_equal "DESIGNATED,PROVIDER", header[:primary_provider]
    assert header[:allergy_flag]
    refute header[:ad_flag]
    cwad = mock.received_calls.find { |c| c[:rpc] == "ORWPT CWAD" }
    getbdp = mock.received_calls.find { |c| c[:rpc] == "BEHOPTPC GETBDP" }
    assert_equal CHART_CONTEXT, cwad[:context]
    refute_equal CHART_CONTEXT, getbdp[:context]
    assert_equal caller_context, mock.current_context
    assert_equal [ CHART_CONTEXT, caller_context ], mock.context_binds.drop(binds_after_setup)
  end
end
