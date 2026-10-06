# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/fhir_client"

# FhirClient leaves the gem (#360, ADR 0010 assertion 7). Step 1 is the
# deprecating release: `RpmsRpc::FhirClient.new` and `RpmsRpc.fhir_client`
# warn on every call, naming the issue, and otherwise behave as before.
# Step 2, the removal, is a later release.
class FhirClientDeprecationTest < Minitest::Test
  def teardown
    RpmsRpc.reset!
  end

  def test_instantiating_fhir_client_warns_once_per_call_naming_the_issue
    _, err = capture_io { RpmsRpc::FhirClient.new(base_url: "http://fhir.example.test") }
    assert_equal 1, err.scan("DEPRECATED").size
    assert_match(/\[rpms_rpc\] DEPRECATED: RpmsRpc::FhirClient /, err)
    assert_includes err, "#360"
    assert_includes err, "ADR 0010"

    _, again = capture_io { RpmsRpc::FhirClient.new(base_url: "http://fhir.example.test") }
    assert_equal 1, again.scan("DEPRECATED").size, "warns on every call, not once per process"
  end

  def test_instantiating_fhir_client_still_builds_the_client
    client, _err = capture_io_and_value { RpmsRpc::FhirClient.new(base_url: "http://fhir.example.test") }
    assert_equal "http://fhir.example.test", client.base_url
  end

  def test_fhir_client_warns_once_per_call_and_still_answers
    mock = RpmsRpc.mock_fhir!
    client, err = capture_io_and_value { RpmsRpc.fhir_client }
    assert_same mock, client
    assert_equal 1, err.scan("DEPRECATED").size
    assert_match(/\[rpms_rpc\] DEPRECATED: RpmsRpc\.fhir_client /, err)
    assert_includes err, "#360"

    _, again = capture_io_and_value { RpmsRpc.fhir_client }
    assert_equal 1, again.scan("DEPRECATED").size, "warns on every call, not once per process"
  end

  def test_fhir_client_unconfigured_warns_then_raises_as_before
    RpmsRpc.reset!
    _, err = capture_io do
      assert_raises(RpmsRpc::NotConfiguredError) { RpmsRpc.fhir_client }
    end
    assert_equal 1, err.scan("DEPRECATED").size
  end

  # The warning is attributed to the caller, not to a line inside the gem.
  def test_warning_points_at_the_callers_line
    _, err = capture_io { RpmsRpc::FhirClient.new(base_url: "http://fhir.example.test") }
    assert_match(/\A#{Regexp.escape(__FILE__)}:\d+: warning: /, err)
  end

  private

  def capture_io_and_value
    value = nil
    _, err = capture_io { value = yield }
    [ value, err ]
  end
end
