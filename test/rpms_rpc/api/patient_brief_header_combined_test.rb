# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/patient"
require_relative "../captured_replies"

# brief_header carries both the #523 designated-primary GETBDP row and the
# ORWPT CWAD read on the caller's option. The replies are seed patient DFN 2's
# with a case manager and a designated primary provider on file, captured from
# the pinned build (test/fixtures/captured_replies/patient-designated-providers.yml),
# replayed through CiaClient's own reply grammar.
class PatientBriefHeaderCombinedTest < Minitest::Test
  SLUG = "patient-designated-providers"
  DFN = "2"
  CALLER_CONTEXT = "CIAV VUECENTRIC"

  def teardown
    RpmsRpc.reset!
  end

  # Proves the designated-primary row is read beside the CWAD letters, and
  # PTINFO, GETBDP and CWAD all run on the caller's option with no option bound.
  def test_designated_primary_row_and_cwad_both_apply
    client = CapturedReplies::ReplayCiaClient.new(
      "BEHOPTCX PTINFO" => [ CapturedReplies.raw(SLUG, "ptinfo_primary") ],
      "BEHOPTPC GETBDP" => [ CapturedReplies.raw(SLUG, "getbdp_primary") ],
      "ORWPT CWAD" => [ CapturedReplies.raw(SLUG, "cwad") ]
    )
    RpmsRpc.configure { |cfg| cfg.client = client }

    header = RpmsRpc::Patient.brief_header(DFN)

    assert_equal "PROFILE,MD", header[:primary_provider]
    assert header[:allergy_flag], "ORWPT CWAD answered A"
    refute header[:ad_flag]
    assert_equal [ [ "BEHOPTCX PTINFO", [ DFN ] ], [ "BEHOPTPC GETBDP", [ DFN ] ], [ "ORWPT CWAD", [ DFN ] ] ],
                 client.calls.map { |c| [ c[:rpc], c[:params] ] }, "three reads and no option bound"
    assert_equal CALLER_CONTEXT, client.current_context
  end
end
