# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/patient"
require_relative "../captured_replies"

# Patient.race is deprecated in favour of Registration.race_ethnicity
# (rpms-rpc#486): it keeps reading PATIENT (#2) .06 for one release and warns
# once per process, naming the replacement. The replies are the build's
# (test/fixtures/captured_replies/patient-race.yml), replayed through CiaClient.
class PatientRaceDeprecationTest < Minitest::Test
  SLUG = "patient-race"

  def setup
    RpmsRpc::Patient.instance_variable_set(:@race_deprecation_warned, nil)
  end

  def teardown
    RpmsRpc::Patient.instance_variable_set(:@race_deprecation_warned, nil)
    RpmsRpc.reset!
  end

  def replay_flow(name)
    client = CapturedReplies::ReplayCiaClient.new(CapturedReplies.flow_script(SLUG, name))
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def test_race_still_reads_point_06_and_warns_naming_the_replacement
    client = replay_flow("race_on_file")

    result = nil
    _out, err = capture_io { result = RpmsRpc::Patient.race(4) }

    assert_equal({ dfn: 4, race: "AMERICAN INDIAN OR ALASKA NATIVE" }, result)
    assert_equal CapturedReplies.flow_calls(SLUG, "race_on_file"),
                 client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params] ] }
    assert_match(/Patient\.race is deprecated/, err)
    assert_match(/Registration\.race_ethnicity/, err)
    assert_match(/rpms-rpc#486/, err)
  end

  def test_the_warning_points_at_the_callers_line
    replay_flow("race_on_file")

    line = __LINE__ + 1
    _out, err = capture_io { RpmsRpc::Patient.race(4) }

    assert_includes err, "#{__FILE__}:#{line}:", "the warning should name the line that called Patient.race"
  end

  def test_it_warns_once_per_process
    replay_flow("race_on_file")
    _out, first = capture_io { RpmsRpc::Patient.race(4) }

    replay_flow("race_blank")
    result = nil
    _out, second = capture_io { result = RpmsRpc::Patient.race(3) }

    refute_empty first
    assert_empty second, "a second call warned again"
    assert_equal({ dfn: 3, race: nil }, result, "a patient with no .06 on file reads as nil")
  end

  def test_an_invalid_dfn_warns_and_sends_nothing
    client = CapturedReplies::ReplayCiaClient.new({})
    RpmsRpc.configure { |cfg| cfg.client = client }

    result = :unset
    _out, err = capture_io { result = RpmsRpc::Patient.race("0") }

    assert_nil result
    assert_empty client.calls
    assert_match(/deprecated/, err)
  end
end
