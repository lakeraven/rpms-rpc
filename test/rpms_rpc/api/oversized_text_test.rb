# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/xwb_client"
require "rpms_rpc/api/progress_note"
require "rpms_rpc/api/exam_component"
require "rpms_rpc/api/health_factor"
require "rpms_rpc/api/immunization_refusal"

# #472 / #474: the XWB client refuses a value over 999 bytes instead of
# mis-framing it. The write APIs that carry free text must keep their own
# contract when that happens: a failure hash that names the limit, never an
# exception that escapes after an earlier call (TIU CREATE RECORD) has already
# filed a record.
class OversizedTextTest < Minitest::Test
  class RecordingSocket
    attr_reader :writes

    def initialize
      @writes = []
    end

    def write(str)
      @writes << str.b
      str.bytesize
    end

    def recv(_n) = ""
    def flush; end
    def close; end
    def closed? = false
    def setsockopt(*); end
  end

  def setup
    @socket = RecordingSocket.new
    client = RpmsRpc::XwbClient.new
    client.instance_variable_set(:@socket, @socket)
    client.instance_variable_set(:@connected, true)
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = client }
  end

  def teardown
    RpmsRpc.reset!
  end

  LONG = "Patient reports #{'x' * 990}"

  def assert_refused(result, shape_keys)
    assert_equal false, result[:success]
    assert_match(/999/, result[:error].to_s, "the failure must name the byte limit")
    shape_keys.each { |k| assert result.key?(k), "keeps the #{k} key of the normal failure shape" }
    assert_empty @socket.writes, "nothing is sent when the value cannot be framed"
  end

  def test_update_text_returns_a_failure_hash_for_a_line_over_999_bytes
    result = RpmsRpc::ProgressNote.update_text("5001", LONG)
    assert_refused(result, %i[success raw error])
  end

  def test_update_text_names_the_offending_line
    text = "short line\n#{LONG}"
    result = RpmsRpc::ProgressNote.update_text("5001", text)
    assert_match(/line 2/, result[:error].to_s)
  end

  def test_update_text_counts_bytes_not_characters
    text = "é" * 500 # 500 characters, 1000 bytes
    result = RpmsRpc::ProgressNote.update_text("5001", text)
    assert_equal false, result[:success]
    assert_match(/999/, result[:error].to_s)
  end

  def test_exam_component_add_returns_its_failure_shape_for_a_long_narrative
    result = RpmsRpc::ExamComponent.add("8791", "2090060", "77", finding: "NORMAL", narrative: "n" * 1000)
    assert_refused(result, %i[success ien raw error])
  end

  def test_health_factor_add_returns_its_failure_shape_for_a_long_narrative
    result = RpmsRpc::HealthFactor.add("8791", "2090060", "55", level: "A", narrative: "n" * 1000)
    assert_refused(result, %i[success ien raw error])
  end

  def test_immunization_refusal_record_returns_its_failure_shape_for_a_long_narrative
    result = RpmsRpc::ImmunizationRefusal.record("8791", "9", reason_ien: "3", narrative: "n" * 1000)
    assert_refused(result, %i[success ien raw error])
  end

  def test_the_original_failure_shapes_have_no_error_key_for_other_failures
    result = RpmsRpc::ProgressNote.update_text("not-an-ien", "x")
    assert_equal({ success: false, raw: nil }, result)
  end
end
