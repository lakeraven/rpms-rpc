# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/rcis_site_params"

class RcisSiteParamsTest < Minitest::Test
  FACILITY_IEN = 55

  def setup
    RpmsRpc.mock! do |m|
      # BMCRPC GTSITPRM — keyed by facility IEN, multi-line KEY^VALUE response.
      m.seed_keyed_collection(:site_params, FACILITY_IEN.to_s, [
        { key: "COMMTHRESH", value: "50000" },
        { key: "NOTIFYHR", value: "72" },
        { key: "PRISYS", value: "I" },
        { key: "FACILITY", value: "General Hospital" },
        { key: "FACILCODE", value: "GH01" },
        { key: "CUSTOM PARAM", value: "enabled" }
      ])

      m.seed_keyed_collection(:site_params, "56", [
        { key: "COMMTHRESH", value: "" },
        { key: "NOTIFYHR", value: nil },
        { key: "PRISYS", value: "" },
        { key: "FACILITY", value: "" }
      ])

      # Partial-blank facility: blank-valued rows should be omitted entirely
      # (matching gateway's `parse_line` + length-< 2 skip), populated rows kept.
      m.seed_keyed_collection(:site_params, "57", [
        { key: "COMMTHRESH", value: "" },
        { key: "NOTIFYHR",   value: "48" },
        { key: "PRISYS",     value: "" },
        { key: "FACILITY",   value: "Test Clinic" }
      ])
    end
  end

  def teardown
    RpmsRpc.reset!
  end

  def test_for_facility_returns_site_parameters
    params = RpmsRpc::RcisSiteParams.for_facility(FACILITY_IEN)

    refute_nil params
    assert_equal 50_000, params[:committee_threshold]
    assert_equal 72, params[:notification_grace_period]
    assert_equal "ihs_2024", params[:priority_system]
    assert_equal "General Hospital", params[:facility_name]
    assert_equal "GH01", params[:facility_code]
    assert_equal "enabled", params[:custom_param]
  end

  def test_for_facility_sends_facility_ien_to_site_params_rpc
    RpmsRpc::RcisSiteParams.for_facility(FACILITY_IEN)

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BMCRPC GTSITPRM" }
    refute_nil call
    assert_equal [ FACILITY_IEN.to_s ], call[:params]
  end

  def test_for_facility_returns_nil_for_blank_zero_or_negative_facility_ien
    assert_nil RpmsRpc::RcisSiteParams.for_facility(nil)
    assert_nil RpmsRpc::RcisSiteParams.for_facility("")
    assert_nil RpmsRpc::RcisSiteParams.for_facility(0)
    assert_nil RpmsRpc::RcisSiteParams.for_facility(-5)
  end

  def test_for_facility_returns_nil_for_unknown_facility
    assert_nil RpmsRpc::RcisSiteParams.for_facility(999_999)
  end

  def test_for_facility_returns_nil_when_all_values_blank
    # Gateway parses with default split("^") which drops trailing empties,
    # then skips rows whose split length is < 2. So a facility whose response
    # is all "KEY^" lines (blank values) yields an empty params hash, which
    # the gateway returns as nil (`params.presence`).
    assert_nil RpmsRpc::RcisSiteParams.for_facility(56)
  end

  def test_for_facility_skips_blank_valued_rows_keeping_populated_ones
    params = RpmsRpc::RcisSiteParams.for_facility(57)

    refute_nil params
    refute params.key?(:committee_threshold), "blank-valued row should be omitted"
    refute params.key?(:priority_system),     "blank-valued row should be omitted"
    assert_equal 48,            params[:notification_grace_period]
    assert_equal "Test Clinic", params[:facility_name]
  end

  def test_module_exposes_documented_methods
    assert RpmsRpc::RcisSiteParams.respond_to?(:for_facility)
  end
end
