# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc/mappings"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/scheduling"

# BSDX HOSPITAL LOCATION (HOSPLOC^BSDX32) writes its two date columns through
# $$GET1^DIQ with no "I" flag (BSDX32.m:35-36), so they arrive EXTERNAL
# ("JAN 15, 2025"), not FileMan internal. Typed :fileman_date they parsed nil
# (#221). The row itself is IEN^NAME^PROVIDER^STOP^INACT^REACT (BSDX32.m:50).
class HospitalLocationWireTest < Minitest::Test
  class RawResponseClient
    def initialize(response) = @response = response
    def supports?(*) = true
    def call_rpc(*) = @response
  end

  def teardown
    RpmsRpc.reset!
  end

  def test_external_inactivate_and_reactivate_dates_parse
    RpmsRpc.reset!
    RpmsRpc.configure do |cfg|
      cfg.client = RawResponseClient.new([
        "I00020HOSPITAL_LOCATION_ID^T00040HOSPITAL_LOCATION^T00030DEFAULT_PROVIDER^" \
        "T00030STOP_CODE_NUMBER^D00020INACTIVATE_DATE^D00020REACTIVATE_DATE\u001E",
        "44^PEDIATRIC CLINIC^PROVIDER,A^FAMILY PRACTICE^JAN 15, 2025^MAR 01, 2025\u001E",
        "45^DENTAL^^DENTAL^^\u001E",
        "\u001F"
      ])
    end

    rows = RpmsRpc::Scheduling.hospital_locations

    assert_equal 2, rows.size
    assert_equal Date.new(2025, 1, 15), rows.first[:inactivate_date]
    assert_equal Date.new(2025, 3, 1), rows.first[:reactivate_date]
    assert_equal "FAMILY PRACTICE", rows.first[:stop_code] # external, BSDX32.m:40
    assert_nil rows.last[:inactivate_date]
    assert_nil rows.last[:reactivate_date]
  end
end
