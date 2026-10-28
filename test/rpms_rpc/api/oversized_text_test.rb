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
# filed a record. ProgressNote.update_text is different (#479): long note lines
# are wrapped before TIU SET DOCUMENT TEXT; the tests below still refuse for
# ExamComponent, HealthFactor, and ImmunizationRefusal.
class OversizedTextTest < Minitest::Test
  EOT = RpmsRpc::Client::EOT
  TIU_SET_TEXT_ACK = "5001^1^1#{EOT}".b

  class RecordingSocket
    attr_reader :writes

    def initialize(reads = [])
      @reads = reads.dup
      @writes = []
    end

    def write(str)
      @writes << str.b
      str.bytesize
    end

    def recv(_n) = @reads.empty? ? "".b : @reads.shift.b
    def flush; end
    def close; end
    def closed? = false
    def setsockopt(*); end
  end

  def setup
    @socket = RecordingSocket.new([ TIU_SET_TEXT_ACK ])
    client = RpmsRpc::XwbClient.new
    client.instance_variable_set(:@socket, @socket)
    client.instance_variable_set(:@connected, true)
    client.instance_variable_set(:@timeout, 1)
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

  def lpack_payload_values(binary)
    values = []
    i = 0
    b = binary.b
    while i <= b.bytesize - 3
      head = b.byteslice(i, 3)
      if head.match?(/\A\d{3}\z/)
        len = head.to_i
        if len <= 999 && i + 3 + len <= b.bytesize
          values << b.byteslice(i + 3, len)
          i += 3 + len
          next
        end
      end
      i += 1
    end
    values
  end

  def assert_wire_writes_lpack_values_at_most_999
    wire = @socket.writes.reduce(+"".b) { |acc, chunk| acc << chunk }
    values = lpack_payload_values(wire)
    refute_empty values, "expected L-PACK payloads on the wire"
    values.each do |v|
      assert_operator v.bytesize, :<=, 999, "L-PACK value length #{v.bytesize} exceeds 999"
    end
  end

  def refute_pre479_update_text_refusal(result)
    return unless result[:error]

    refute_match(/999/, result[:error].to_s, "update_text must wrap, not refuse with the 999-byte limit")
  end

  def test_update_text_returns_a_failure_hash_for_a_line_over_999_bytes
    result = RpmsRpc::ProgressNote.update_text("5001", LONG)
    refute_empty @socket.writes, "wrapped update must reach the wire"
    assert_wire_writes_lpack_values_at_most_999
    refute_pre479_update_text_refusal(result)
  end

  def test_update_text_names_the_offending_line
    text = "short line\n#{LONG}"
    refusing = Object.new
    refusing.define_singleton_method(:call_rpc) { |_rpc, *_params| raise RpmsRpc::Client::FrameTooLongError, "stub wire refusal" }
    RpmsRpc.configure { |cfg| cfg.client = refusing }

    result = RpmsRpc::ProgressNote.update_text("5001", text)
    assert_equal false, result[:success]
    assert_nil result[:raw]
    assert result.key?(:error), "keeps the error key of the normal failure shape"
    refute_empty result[:error].to_s
    refute_includes result[:error].to_s, LONG
  end

  def test_update_text_counts_bytes_not_characters
    text = "é" * 500 # 500 characters, 1000 bytes
    result = RpmsRpc::ProgressNote.update_text("5001", text)
    refute_empty @socket.writes, "wrapped update must reach the wire"
    assert_wire_writes_lpack_values_at_most_999
    refute_pre479_update_text_refusal(result)
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
