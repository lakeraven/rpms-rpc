# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/vital"

# Vital.validate asks BEHOVM VALIDATE (VALIDATE^BEHOVM) about each
# measurement: the type, the units flag and the value (#665). The build
# answers the value it would file, or "-1^<reason>". VALIDATE files nothing.
class VitalValidateLiveTest < LiveSpec::Test
  DFN = 4 # DEMO,PATIENT ONE; VALIDATE does not read it

  def test_a_value_in_range_is_valid_and_one_out_of_range_carries_the_servers_reason
    result = RpmsRpc::Vital.validate(DFN, [ { abbreviation: "TMP", value: 97 }, { abbreviation: "TMP", value: 999 } ])

    refute result[:valid]
    assert_equal [ 1 ], result[:errors].map { |e| e[:index] }
    assert_match(/\AInput must be between/, result[:errors].first[:error_message])
    puts "\n#{persona}: #{result[:errors].first[:error_message]}"
  end

  def test_blood_pressure_and_pulse_in_range_are_valid
    result = RpmsRpc::Vital.validate(DFN, [ { abbreviation: "BP", value: "130/90" }, { abbreviation: "PU", value: 80 } ])

    assert result[:valid], result.inspect
  end

  def test_a_vital_type_the_build_does_not_have_is_an_error_not_a_raise
    result = RpmsRpc::Vital.validate(DFN, [ { abbreviation: "ZZZ", value: 5 } ])

    refute result[:valid]
  end
end
