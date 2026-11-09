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
    records = FeaturesTestHelper.chart_banner_records("ORWPT CWAD" => { "contexts" => [ CPRS ] })
    Dir.mktmpdir("features-banner-cwad-ctx-") do |tmpdir|
      tag = write_synthetic_inventory(tmpdir, "features-banner-cwad-wrong-context-ydb", records: records)
      kw = { build: tag, inventories_dir: tmpdir }
      refute available?(:patient_chart_banner, **kw, context: CIAV)
      refute available?(:patient_chart_banner, **kw, context: CPRS)
    end
  end

  def test_banner_unavailable_when_orwpt_cwad_absent_from_build
    records = FeaturesTestHelper.chart_banner_records.reject { |r| r["name"] == "ORWPT CWAD" }
    Dir.mktmpdir("features-banner-no-cwad-") do |tmpdir|
      tag = write_synthetic_inventory(tmpdir, "features-banner-no-orwpt-cwad-ydb", records: records)
      refute available?(:patient_chart_banner,
                        build: tag,
                        inventories_dir: tmpdir,
                        context: CIAV)
    end
  end

  def test_banner_available_when_all_three_rpcs_client_callable_under_session_context
    Dir.mktmpdir("features-banner-all-ok-") do |tmpdir|
      tag = write_synthetic_inventory(tmpdir, "features-banner-all-ok-ydb")
      assert available?(:patient_chart_banner,
                        build: tag,
                        inventories_dir: tmpdir,
                        context: CIAV)
    end
  end
end
