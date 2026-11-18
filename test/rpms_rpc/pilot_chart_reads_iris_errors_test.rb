# frozen_string_literal: true

require "minitest/autorun"
require_relative "captured_replies"
require_relative "pilot_chart_reads_test"

# The pilot readiness grader on an IRIS build's error replies (rpms-rpc#666).
# Each of the eight chart reads was captured from a throwaway IRIS container
# for a patient that does not exist and for an input that faults inside the
# routine (tools/captured_replies/iris-chart-read-errors.rb). Every capture
# replays through CiaClient's own reply reader, and none may count as a record
# row: an M error never becomes rows (CIA sends it as an error frame, which
# raises), and a missing patient's rows are blanks or a sentinel. The M error
# text is also graded as a row, for a path that hands it over as data.
class RpmsRpc::PilotChartReadsIrisErrorsTest < Minitest::Test
  SLUG = "iris-chart-read-errors"
  GRADER = RpmsRpc::PilotChartReadsTest
  CHART_READS = GRADER::CHART_READ_SLICE.map { |slice| slice[:rpc] }.freeze

  def captures = CapturedReplies.file(SLUG).fetch("captures")

  def replay(capture)
    client = CapturedReplies::ReplayCiaClient.new(capture.fetch("rpc") => [ capture.fetch("raw_return") ])
    client.call_rpc(capture.fetch("rpc"), *capture.fetch("inputs"))
  end

  def test_every_chart_read_has_a_missing_patient_and_an_m_error_capture_from_iris
    assert_equal "bcer-9.0-20261107-312e774-iris", CapturedReplies.file(SLUG).fetch("release_tag")
    CHART_READS.each do |rpc|
      names = captures.select { |c| c["rpc"] == rpc }.map { |c| c["name"] }
      assert(names.any? { |n| n.end_with?("_missing_patient") }, "#{rpc} has no missing-patient capture")
      assert(names.any? { |n| n.end_with?("_m_error") }, "#{rpc} has no M error capture")
    end
  end

  def test_a_missing_patient_reply_is_no_record
    captures.select { |c| c["name"].end_with?("_missing_patient") }.each do |capture|
      rows = Array(replay(capture))
      rows.each do |row|
        refute GRADER.record_row?(row), "#{capture['name']}: #{row.inspect} graded as a record row"
      end
    end
  end

  def test_an_m_error_raises_and_its_text_is_no_record
    captures.select { |c| c["name"].end_with?("_m_error") }.each do |capture|
      error = assert_raises(RpmsRpc::Client::RpcMError, capture["name"]) { replay(capture) }
      line = error.message[/<[A-Z]+>\S+/]
      refute_nil line, "#{capture['name']}: no IRIS <NAME>LABEL+off^ROUTINE in #{error.message.inspect}"
      assert GRADER.m_error_text?(line), "#{capture['name']}: #{line.inspect} not recognised as M error text"
      refute GRADER.record_row?(line), "#{capture['name']}: #{line.inspect} graded as a record row"
    end
  end
end
