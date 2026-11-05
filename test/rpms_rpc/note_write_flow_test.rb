# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "rpms_rpc"
require "rpms_rpc/wire_capture"
require "rpms_rpc/api/progress_note"
require "rpms_rpc/api/e_signature"

# Issue #564 / #224 (TIU note writes): NoteWriteFlow drives create → lock →
# set text → read-back → unlock → sign through the public API with a
# recording client. These tests fail until lib/rpms_rpc/wire_capture.rb
# defines NoteWriteFlow.
class RpmsRpc::NoteWriteFlowTest < Minitest::Test
  CREATE_RPC = "TIU CREATE RECORD"
  LOCK_RPC = "TIU LOCK RECORD"
  SET_TEXT_RPC = "TIU SET DOCUMENT TEXT"
  GET_TEXT_RPC = "TIU GET RECORD TEXT"
  UNLOCK_RPC = "TIU UNLOCK RECORD"
  SIGN_RPC = "TIU SIGN RECORD"

  LOCKED_ELSEWHERE = "1^ Another session has this record locked."
  CIA_SEQ = "5"

  def framed_payload(payload)
    "#{CIA_SEQ}\x00#{payload}"
  end

  def structure_dump(value)
    JSON.generate(value)
  rescue StandardError
    Marshal.dump(value)
  end

  class ScriptedClient
    attr_reader :calls

    def initialize(steps, framer:)
      @steps = steps.dup
      @calls = []
      @framer = framer
    end

    def call_rpc_raw(rpc, *params)
      @calls << { rpc: rpc, params: params }
      step = @steps.shift
      raise "unexpected RPC #{rpc} (no scripted reply)" if step.nil?
      raise "expected #{step[:rpc]}, got #{rpc}" unless step[:rpc] == rpc

      @framer.call(step[:raw])
    end

    def call_rpc(rpc, *params)
      raw = call_rpc_raw(rpc, *params)
      raw.sub(/\A.\x00/m, "")
    end
  end

  def setup
    RpmsRpc.reset!
  end

  def teardown
    RpmsRpc.reset!
  end

  def flow_class
    assert defined?(RpmsRpc::WireCapture::NoteWriteFlow),
           "RpmsRpc::WireCapture::NoteWriteFlow missing (issue #564)"
    RpmsRpc::WireCapture::NoteWriteFlow
  end

  def run_flow(client, esig: nil)
    flow_class.run(client, esig: esig)
  end

  def note_text
    flow_class::NOTE_TEXT
  end

  def withheld
    flow_class::WITHHELD
  end

  def assert_long_line_in_note_text
    lines = note_text.split(/\r?\n/, -1)
    assert lines.any? { |line| line.bytesize > RpmsRpc::ProgressNote::WRAP_WIDTH },
           "NOTE_TEXT must include at least one line longer than WRAP_WIDTH"
  end

  def test_constants_match_the_pinned_seed_flow
    flow = flow_class
    assert_equal "4", flow::DFN
    assert_equal "4", flow::VISIT_IEN
    assert_equal "248", flow::TITLE_IEN
    assert_equal "[signature code withheld]", flow::WITHHELD
    assert_long_line_in_note_text
  end

  def test_run_records_create_lock_set_text_read_back_unlock_in_order_without_sign
    note_ien = "6"
    body_line = note_text.lines.find { |l| l.bytesize > RpmsRpc::ProgressNote::WRAP_WIDTH } ||
                note_text.lines.first
    read_back = "S: #{body_line.strip}\nO: synthetic observation\n"
    client = ScriptedClient.new(
      [
        { rpc: CREATE_RPC, raw: note_ien },
        { rpc: LOCK_RPC, raw: "0" },
        { rpc: SET_TEXT_RPC, raw: "#{note_ien}^1^1" },
        { rpc: GET_TEXT_RPC, raw: read_back },
        { rpc: UNLOCK_RPC, raw: "0" }
      ],
      framer: method(:framed_payload)
    )
    RpmsRpc.configure { |cfg| cfg.client = client }

    result = run_flow(client, esig: nil)

    assert_equal [ CREATE_RPC, LOCK_RPC, SET_TEXT_RPC, GET_TEXT_RPC, UNLOCK_RPC ],
                 result.keys
    refute result.key?(SIGN_RPC)

    assert_equal [ flow_class::DFN, flow_class::TITLE_IEN, "", "", flow_class::VISIT_IEN ],
                 result[CREATE_RPC]["inputs"]
    assert_equal framed_payload(note_ien), result[CREATE_RPC]["raw"]

    [ LOCK_RPC, SET_TEXT_RPC, GET_TEXT_RPC, UNLOCK_RPC ].each do |rpc|
      assert_equal [ note_ien ], result[rpc]["inputs"][0..0],
                   "#{rpc} must carry the create IEN as first input"
    end

    set_inputs = result[SET_TEXT_RPC]["inputs"]
    assert_equal 2, set_inputs.length
    text_param = set_inputs[1]
    assert text_param.is_a?(Hash), "set-text list param must be recorded as a Hash"
    assert text_param.keys.all?(String), "set-text Hash keys must be String keys for YAML safety"
    assert_equal "1^1", text_param["HDR"]
    text_param.each do |key, piece|
      next if key == "HDR"

      assert_operator piece.bytesize, :<=, RpmsRpc::ProgressNote::WRAP_WIDTH,
                      "#{key} piece exceeds WRAP_WIDTH"
    end
  end

  def test_run_includes_sign_with_withheld_second_input_when_esig_given
    note_ien = "6"
    esig = "synthetic-dev-code"
    client = ScriptedClient.new(
      [
        { rpc: CREATE_RPC, raw: note_ien },
        { rpc: LOCK_RPC, raw: "0" },
        { rpc: SET_TEXT_RPC, raw: "#{note_ien}^1^1" },
        { rpc: GET_TEXT_RPC, raw: "S: line\n" },
        { rpc: UNLOCK_RPC, raw: "0" },
        { rpc: SIGN_RPC, raw: "0" }
      ],
      framer: method(:framed_payload)
    )
    RpmsRpc.configure { |cfg| cfg.client = client }

    result = run_flow(client, esig: esig)

    assert result.key?(SIGN_RPC), "sign step required when esig is a non-blank String"
    sign_inputs = result[SIGN_RPC]["inputs"]
    assert_equal note_ien, sign_inputs[0]
    assert_equal withheld, sign_inputs[1]

    sign_call = client.calls.find { |c| c[:rpc] == SIGN_RPC }
    refute_nil sign_call, "recorder must intercept call_rpc_raw for TIU SIGN RECORD"
    wire_esig = sign_call[:params][1]
    assert RpmsRpc::XwbCipher.framed?(wire_esig),
           "client must receive XWB-encrypted signature at inputs[1]"
    refute_equal esig, wire_esig
    assert_equal framed_payload("0"), result[SIGN_RPC]["raw"]

    dump = structure_dump(result)
    refute_includes dump, esig
    refute_includes dump, wire_esig
  end

  def test_create_failure_stops_before_lock
    client = ScriptedClient.new(
      [ { rpc: CREATE_RPC, raw: "0^Patient & Visit required." } ],
      framer: method(:framed_payload)
    )
    RpmsRpc.configure { |cfg| cfg.client = client }

    result = run_flow(client, esig: "anything")

    assert_equal [ CREATE_RPC ], result.keys
    assert_equal framed_payload("0^Patient & Visit required."), result[CREATE_RPC]["raw"]
  end

  def test_lock_failure_skips_set_text_and_unlock
    note_ien = "6"
    client = ScriptedClient.new(
      [
        { rpc: CREATE_RPC, raw: note_ien },
        { rpc: LOCK_RPC, raw: LOCKED_ELSEWHERE }
      ],
      framer: method(:framed_payload)
    )
    RpmsRpc.configure { |cfg| cfg.client = client }

    result = run_flow(client, esig: "anything")

    assert_equal [ CREATE_RPC, LOCK_RPC ], result.keys
    refute result.key?(SET_TEXT_RPC)
    refute result.key?(UNLOCK_RPC)
    refute result.key?(SIGN_RPC)
  end
end
