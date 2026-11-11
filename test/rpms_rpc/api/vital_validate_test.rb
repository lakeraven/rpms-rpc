# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/vital"
require_relative "../captured_replies"

# Vital.validate over BEHOVM VALIDATE, VALIDATE(DATA,VCTL,METRIC,X)
# (BEHOVM.m:359). The replies are the build's
# (test/fixtures/captured_replies/behovm-validate.yml): validate run as
# PROFILE,MD on a throwaway container, recorded as flows and replayed through
# CiaClient. The live spec is test/live/vital_validate_live_test.rb.
class VitalValidateTest < Minitest::Test
  SLUG = "behovm-validate"
  Vital = RpmsRpc::Vital

  def teardown
    RpmsRpc.reset!
  end

  def replay(script = {})
    @client = CapturedReplies::ReplayCiaClient.new(script)
    RpmsRpc.configure { |cfg| cfg.client = @client }
    @client
  end

  def replay_flow(name) = replay(CapturedReplies.flow_script(SLUG, name))

  def sent = @client.calls.map { |c| [ c[:rpc], c[:params] ] }

  # The type, the units flag (-1: the type's default units), then the
  # value; no DFN (#665).
  def test_each_measurement_sends_type_units_and_value
    replay_flow("accepted")
    Vital.validate(4, [ { abbreviation: "TMP", value: 97 }, { abbreviation: "PU", value: 80 },
                        { abbreviation: "BP", value: "130/90" } ])

    assert_equal CapturedReplies.flow_calls(SLUG, "accepted"), sent
    assert_equal [ "TMP", "-1", "97" ], sent.first.last
  end

  def test_values_the_build_accepts_are_valid
    replay_flow("accepted")
    result = Vital.validate(4, [ { abbreviation: "TMP", value: 97 }, { abbreviation: "PU", value: 80 },
                                 { abbreviation: "BP", value: "130/90" } ])

    assert_equal({ valid: true, errors: [] }, result)
  end

  def test_a_refused_value_is_an_error_with_the_servers_reason
    replay_flow("refused")
    result = Vital.validate(4, [ { abbreviation: "TMP", value: 97 }, { abbreviation: "TMP", value: 999 },
                                 { abbreviation: "TMP", value: "" } ])

    refute result[:valid]
    assert_equal [ { index: 1, abbreviation: "TMP", value: 999, error_message: "Input must be between 70 and 120 F." },
                   { index: 2, abbreviation: "TMP", value: "", error_message: "Input must be a numeric value." } ],
                 result[:errors]
  end

  # The build answers the value it would file, in the type's default units:
  # not the value sent, and still valid.
  def test_a_value_the_build_converts_is_valid
    replay_flow("converted")

    assert Vital.validate(4, [ { abbreviation: "TMP", value: "36C" } ])[:valid]
  end

  def test_metric_sends_the_units_flag
    replay_flow("metric")
    result = Vital.validate(4, [ { abbreviation: "TMP", value: 97 } ], metric: 1)

    assert_equal [ "TMP", "1", "97" ], sent.first.last
    assert_equal "Input must be between 21.11 and 48.89 C.", result[:errors].first[:error_message]
  end

  # VALIDATE faults on a type the build does not have; that measurement is
  # an error rather than a raise.
  def test_a_type_the_build_does_not_have_is_an_error
    replay_flow("unknown_type")
    result = Vital.validate(4, [ { abbreviation: "ZZZ", value: 5 } ])

    refute result[:valid]
    assert_equal "The server could not validate a ZZZ measurement", result[:errors].first[:error_message]
  end

  # The frame validate sent before #665 dies on the build.
  def test_the_old_frame_faults_on_the_build
    replay("BEHOVM VALIDATE" => [ CapturedReplies.raw(SLUG, "old_frame") ])

    assert_raises(RpmsRpc::Client::RpcMError) { RpmsRpc::DataMapper.vital_validate.fetch_scalar("TMP|97", "4") }
  end

  def test_no_measurements_sends_nothing
    replay

    assert_equal({ valid: true, errors: [] }, Vital.validate(4, []))
    assert_empty @client.calls
  end
end
