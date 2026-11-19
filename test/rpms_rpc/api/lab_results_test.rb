# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/lab"
require_relative "../captured_replies"

# Lab.results reads a patient's resulted specimens over a date range by
# stepping ORWLRR INTERIMG older (rpms-rpc#732). Each test replays a flow
# the gem ran as PROVIDER,TEST on the pinned build, on synthetic lab data
# its capture setup filed (test/fixtures/captured_replies/lab-results.yml,
# spec tools/captured_replies/lab-results.rb), and checks the gem sent
# exactly the recorded calls. Proven live in
# test/live/lab_vital_medication_reads_live_test.rb.
class LabResultsTest < Minitest::Test
  SLUG = "lab-results"
  FROM = Date.new(2026, 10, 1)
  TO = Date.new(2026, 11, 19)

  def teardown
    RpmsRpc.reset!
  end

  def replay(flow, script = CapturedReplies.flow_script(SLUG, flow))
    @client = CapturedReplies::ReplayCiaClient.new(script)
    RpmsRpc.configure { |cfg| cfg.client = @client }
  end

  def sent = @client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params] ] }

  def test_the_range_lists_released_specimens_newest_first
    replay("in_range")

    got = RpmsRpc::Lab.results(990_031, from: FROM, to: TO)

    assert_equal [ Time.new(2026, 11, 10, 9, 15), Time.new(2026, 11, 3, 8, 30) ], got.map { |s| s[:collected_at] }
    newest = got.first
    assert_equal [ "CH", 70, "BLOOD", "CH 1110 2", "PROVIDER,TEST", :final, Time.new(2026, 11, 10, 12, 0) ],
                 newest.values_at(:area, :specimen_ien, :specimen, :accession, :provider, :status, :released_at)
    assert_equal [ { test_ien: 2_096_008, name: "_COVID-19(Abbott ID NOW)", value: "COVID-19 Negative", flag: nil, units: nil, range: nil, loinc: nil },
                   { test_ien: 2_096_016, name: "POC GLUCOSE", value: "96", flag: nil, units: "mg/dL", range: "70 - 110", loinc: "2340-8" } ],
                 newest[:tests]
    assert_equal "142", got.last[:tests].first[:value]
    assert_equal CapturedReplies.flow_calls(SLUG, "in_range"), sent
  end

  # The walk starts the day after +to+, steps from each header's own
  # COLLECTED, and stops at the first specimen before +from+.
  def test_the_walk_steps_from_each_collected_date_and_stops_before_from
    replay("in_range")

    RpmsRpc::Lab.results(990_031, from: FROM, to: TO)

    assert_equal [ "3261120", "3261110.0915", "3261103.083" ], sent.map { |_, params| params[1] }
  end

  def test_a_patient_with_no_lab_data_has_no_results
    replay("no_lab_data")

    assert_empty RpmsRpc::Lab.results(4, from: FROM, to: TO)
    assert_equal CapturedReplies.flow_calls(SLUG, "no_lab_data"), sent
  end

  def test_a_bad_dfn_or_range_sends_nothing
    replay("no_lab_data")

    assert_empty RpmsRpc::Lab.results("4^1", from: FROM, to: TO)
    assert_empty RpmsRpc::Lab.results(4, from: TO, to: FROM)
    assert_empty RpmsRpc::Lab.results(4, from: "3261001", to: TO)
    assert_empty sent
  end

  # GRID^LR7OGMG writes the released line from DATE REPORT COMPLETED, blank
  # when it is unset (an accessioned test still in the lab). The captured
  # newest specimen with that line blanked reads as pending.
  def test_a_specimen_with_no_released_date_is_pending
    script = CapturedReplies.flow_script(SLUG, "in_range")
    script["ORWLRR INTERIMG"][0] = script["ORWLRR INTERIMG"][0].sub("11/10/2026 12:00 PM".b, "".b)
    replay("in_range", script)

    newest = RpmsRpc::Lab.results(990_031, from: FROM, to: TO).first

    assert_equal [ :pending, nil ], newest.values_at(:status, :released_at)
  end

  # The captured newest specimen with its header's AREA corrupted: a row
  # the gem cannot read raises instead of becoming an empty result.
  def test_a_header_it_cannot_read_raises
    script = CapturedReplies.flow_script(SLUG, "in_range")
    script["ORWLRR INTERIMG"][0] = script["ORWLRR INTERIMG"][0].sub("^CH^".b, "^ZZ^".b)
    replay("in_range", script)

    assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Lab.results(990_031, from: FROM, to: TO) }
  end

  # The newest specimen answered twice: a reply that does not step older
  # raises rather than loop.
  def test_a_reply_that_does_not_step_older_raises
    script = CapturedReplies.flow_script(SLUG, "in_range")
    script["ORWLRR INTERIMG"][1] = script["ORWLRR INTERIMG"][0]
    replay("in_range", script)

    assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Lab.results(990_031, from: FROM, to: TO) }
  end
end
