# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/patient"
require_relative "features_test_helper"

# #384: patient_chart_banner RPCs must match Patient.brief_header; availability
# requires every banner RPC (including ORWPT CWAD) under the session context.
class FeaturesBannerTest < Minitest::Test
  include FeaturesTestHelper

  DFN = "384"
  CIAV = "CIAV VUECENTRIC"
  CPRS = "OR CPRS GUI CHART"

  def setup
    RpmsRpc.mock!
    features!.reset!
  end

  def teardown
    RpmsRpc.reset!
    features!.reset!
  end

  def test_patient_chart_banner_rpcs_match_brief_header_code_path
    mock = RpmsRpc.client
    mock.create_context(CIAV)
    mock.seed(:patient_ptinfo, DFN,
              { name: "SYNTH,PATIENT", sex: "F", dob_raw: "3010101", mrn: "MRN01", primary_provider: "PROV,ONE" })
    mock.seed_raw_lines(:patient_designated_provider, DFN, [])
    mock.seed_scalar(:patient_cwad, DFN, "WA")

    RpmsRpc::Patient.brief_header(DFN)

    from_calls = mock.received_calls.map { |c| c[:rpc] }.uniq.sort
    banner_rpcs = feature_rpcs(meta_for(:patient_chart_banner)).map(&:to_s).sort
    assert_equal from_calls, banner_rpcs
  end

  def test_banner_unavailable_when_orwpt_cwad_not_callable_under_session_context
    reach_lines = [
      "BEHOPTCX PTINFO^client-callable^1^1^#{CIAV}^",
      "BEHOPTPC GETBDP^client-callable^1^1^#{CIAV}^",
      "ORWPT CWAD^client-callable^1^1^#{CPRS}^"
    ]
    Dir.mktmpdir("features-banner-cwad-ctx-") do |tmpdir|
      tag = write_synthetic_inventory(tmpdir, "features-banner-cwad-wrong-context-ydb", reach_lines: reach_lines)
      kw = { build: tag, inventories_dir: tmpdir }
      refute available?(:patient_chart_banner, **kw, context: CIAV)
      refute available?(:patient_chart_banner, **kw, context: CPRS)
    end
  end

  def test_banner_unavailable_when_orwpt_cwad_absent_from_build
    registry_lines = [
      "BEHOPTCX PTINFO^PTINFO^BEHOPTCX^1",
      "BEHOPTPC GETBDP^GETBDP^BEHOPTPC^1"
    ]
    reach_lines = [
      "BEHOPTCX PTINFO^client-callable^1^1^#{CIAV}^",
      "BEHOPTPC GETBDP^client-callable^1^1^#{CIAV}^"
    ]
    Dir.mktmpdir("features-banner-no-cwad-") do |tmpdir|
      tag = write_synthetic_inventory(
        tmpdir, "features-banner-no-orwpt-cwad-ydb",
        reach_lines: reach_lines,
        registry_lines: registry_lines
      )
      refute available?(:patient_chart_banner,
                        build: tag,
                        inventories_dir: tmpdir,
                        context: CIAV)
    end
  end

  def test_banner_available_when_all_three_rpcs_client_callable_under_session_context
    Dir.mktmpdir("features-banner-all-ok-") do |tmpdir|
      tag = write_synthetic_inventory(tmpdir, "features-banner-all-ok-ydb",
                                      reach_lines: CHART_BANNER_REACH_OK_LINES)
      assert available?(:patient_chart_banner,
                        build: tag,
                        inventories_dir: tmpdir,
                        context: CIAV)
    end
  end
end
