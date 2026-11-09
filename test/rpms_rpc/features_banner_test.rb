# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/api/patient"
require_relative "features_test_helper"
require_relative "captured_replies"

# #384: patient_chart_banner RPCs must match Patient.brief_header; availability
# requires every banner RPC (including ORWPT CWAD) under the session context.
class FeaturesBannerTest < Minitest::Test
  include FeaturesTestHelper

  CIAV = "CIAV VUECENTRIC"
  CPRS = "OR CPRS GUI CHART"

  def setup
    features!.reset!
  end

  def teardown
    RpmsRpc.reset!
    features!.reset!
  end

  # The calls brief_header makes, answered with the replies the demo patient's
  # banner got live (test/fixtures/captured_replies/patient-brief-header.yml).
  def test_patient_chart_banner_rpcs_match_brief_header_code_path
    slug = "patient-brief-header"
    client = CapturedReplies::ReplayCiaClient.new(
      "BEHOPTCX PTINFO" => [ CapturedReplies.raw(slug, "ptinfo") ],
      "BEHOPTPC GETBDP" => [ CapturedReplies.raw(slug, "getbdp") ],
      "ORWPT CWAD" => [ CapturedReplies.raw(slug, "cwad") ]
    )
    RpmsRpc.configure { |cfg| cfg.client = client }

    header = RpmsRpc::Patient.brief_header("4")

    assert_equal "DEMO,PATIENT ONE", header[:name], "the captured banner reads back"
    from_calls = client.rpcs_called.uniq.sort
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
