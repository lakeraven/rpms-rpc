# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "yaml"
require "rpms_rpc"
require "rpms_rpc/wire_capture"
require "rpms_rpc/api/progress_note"
require "rpms_rpc/api/e_signature"

# Issue #564 / #224 (TIU note writes): NoteWriteFlow drives create → lock →
# set text → read-back → unlock → sign through the public API with a
# recording client. These tests fail until lib/rpms_rpc/wire_capture.rb
# defines NoteWriteFlow.
class RpmsRpc::NoteWriteFlowTest < Minitest::Test
  GETVISIT_RPC = "BEHOENCX GETVISIT"
  CREATE_RPC = "TIU CREATE RECORD"
  LOCK_RPC = "TIU LOCK RECORD"
  SET_TEXT_RPC = "TIU SET DOCUMENT TEXT"
  GET_TEXT_RPC = "TIU GET RECORD TEXT"
  UNLOCK_RPC = "TIU UNLOCK RECORD"
  SIGN_RPC = "TIU SIGN RECORD"

  LOCKED_ELSEWHERE = "1^ Another session has this record locked."
  CIA_SEQ = "5"
  VISIT_PATIENT_OK = "3^3260902.12^E^4^^0"

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

      if step[:raise]
        ex = step[:raise].is_a?(Class) ? step[:raise] : RuntimeError
        raise ex, step[:message] || "scripted raise"
      end

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

  def visit_step(raw: VISIT_PATIENT_OK)
    { rpc: GETVISIT_RPC, raw: raw }
  end

  def flow_steps(*steps)
    [ visit_step ] + steps
  end

  def withheld
    flow_class::WITHHELD
  end

  def assert_getvisit_capture(result, raw: VISIT_PATIENT_OK)
    capture = result[GETVISIT_RPC]
    refute_nil capture, "NoteWriteFlow must record BEHOENCX GETVISIT"
    assert_equal [ flow_class::VISIT_IEN ], capture["inputs"]
    assert_equal framed_payload(raw), capture["raw"]
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
      flow_steps(
        { rpc: CREATE_RPC, raw: note_ien },
        { rpc: LOCK_RPC, raw: "0" },
        { rpc: SET_TEXT_RPC, raw: "#{note_ien}^1^1" },
        { rpc: GET_TEXT_RPC, raw: read_back },
        { rpc: UNLOCK_RPC, raw: "0" }
      ),
      framer: method(:framed_payload)
    )
    RpmsRpc.configure { |cfg| cfg.client = client }

    result = run_flow(client, esig: nil)

    assert_equal [ GETVISIT_RPC, CREATE_RPC, LOCK_RPC, SET_TEXT_RPC, GET_TEXT_RPC, UNLOCK_RPC ],
                 result.keys
    refute result.key?(SIGN_RPC)
    assert_getvisit_capture(result)

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
    read_back = wrapped_read_back_payload(note_ien)
    client = ScriptedClient.new(
      flow_steps(
        { rpc: CREATE_RPC, raw: note_ien },
        { rpc: LOCK_RPC, raw: "0" },
        { rpc: SET_TEXT_RPC, raw: "#{note_ien}^1^1" },
        { rpc: GET_TEXT_RPC, raw: read_back },
        { rpc: UNLOCK_RPC, raw: "0" },
        { rpc: SIGN_RPC, raw: "0" }
      ),
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
      flow_steps({ rpc: CREATE_RPC, raw: "0^Patient & Visit required." }),
      framer: method(:framed_payload)
    )
    RpmsRpc.configure { |cfg| cfg.client = client }

    result = run_flow(client, esig: "anything")

    assert_equal [ GETVISIT_RPC, CREATE_RPC ], result.keys
    assert_getvisit_capture(result)
    assert_equal framed_payload("0^Patient & Visit required."), result[CREATE_RPC]["raw"]
  end

  def test_lock_failure_skips_set_text_and_unlock
    note_ien = "6"
    client = ScriptedClient.new(
      flow_steps(
        { rpc: CREATE_RPC, raw: note_ien },
        { rpc: LOCK_RPC, raw: LOCKED_ELSEWHERE }
      ),
      framer: method(:framed_payload)
    )
    RpmsRpc.configure { |cfg| cfg.client = client }

    result = run_flow(client, esig: "anything")

    assert_equal [ GETVISIT_RPC, CREATE_RPC, LOCK_RPC ], result.keys
    assert_getvisit_capture(result)
    refute result.key?(SET_TEXT_RPC)
    refute result.key?(UNLOCK_RPC)
    refute result.key?(SIGN_RPC)
  end

  def test_reply_containing_signature_code_is_quarantined_not_redacted_in_raw
    esig = "731905"
    note_ien = "2731905"
    body_line = note_text.lines.first.to_s.chomp
    client = ScriptedClient.new(
      flow_steps(
        { rpc: CREATE_RPC, raw: note_ien },
        { rpc: LOCK_RPC, raw: "0" },
        { rpc: SET_TEXT_RPC, raw: "#{note_ien}^1^1" },
        { rpc: GET_TEXT_RPC, raw: "H\n\n#{body_line}\n" },
        { rpc: UNLOCK_RPC, raw: "0" }
      ),
      framer: method(:framed_payload)
    )
    RpmsRpc.configure { |cfg| cfg.client = client }

    result = run_flow(client, esig: esig)

    create = result[CREATE_RPC]
    assert create.key?("error"), "create reply embeds the signature code — must not return edited raw"
    refute create.key?("raw"), "quarantined step must not carry raw"
    assert_match(/signature code/i, create["error"])
    assert_match(/not recorded/i, create["error"])
    refute_includes create["error"], esig

    result.each_value do |capture|
      next unless capture.is_a?(Hash) && capture["raw"].is_a?(String)

      refute_includes capture["raw"], esig
      refute_includes capture["raw"], withheld
    end
  end

  def test_quarantine_secrets_replaces_tainted_captures_and_leaves_others_byte_identical
    flow = flow_class
    assert flow.respond_to?(:quarantine_secrets), "NoteWriteFlow.quarantine_secrets missing"

    secret = "731905"
    pristine_raw = "5\x009"
    tainted_raw = "5\x0012731905"
    captures = {
      CREATE_RPC => { "inputs" => [ "4" ], "raw" => pristine_raw.dup },
      LOCK_RPC => { "inputs" => [ "9" ], "raw" => "5\x000" },
      SET_TEXT_RPC => {
        "inputs" => [ "9", { "HDR" => "1^1" } ],
        "raw" => tainted_raw.dup
      }
    }
    out = flow.quarantine_secrets(captures, [ secret ])

    assert_equal pristine_raw, out[CREATE_RPC]["raw"],
                 "untainted capture raw must be unchanged byte-for-byte"
    tainted = out[SET_TEXT_RPC]
    assert tainted.key?("error"), "capture whose raw contains a secret must become an error"
    refute tainted.key?("raw")
    assert_match(/signature code/i, tainted["error"])
    refute_includes tainted["error"], secret

    input_tainted = flow.quarantine_secrets(
      { GET_TEXT_RPC => { "inputs" => [ secret ], "raw" => "5\x00ok" } },
      [ secret ]
    )
    assert input_tainted[GET_TEXT_RPC].key?("error")
    refute input_tainted[GET_TEXT_RPC].key?("raw")
  end

  def test_set_text_raise_still_unlocks_and_skips_sign
    note_ien = "6"
    client = ScriptedClient.new(
      flow_steps(
        { rpc: CREATE_RPC, raw: note_ien },
        { rpc: LOCK_RPC, raw: "0" },
        { rpc: SET_TEXT_RPC, raise: RuntimeError, message: "SET failed" },
        { rpc: UNLOCK_RPC, raw: "0" }
      ),
      framer: method(:framed_payload)
    )
    RpmsRpc.configure { |cfg| cfg.client = client }

    result = run_flow(client, esig: "synthetic-esig-77")

    assert result[SET_TEXT_RPC].key?("error"), "set-text failure must be recorded as error"
    unlock = result[UNLOCK_RPC]
    refute_nil unlock, "lock held after failed set-text must still be released"
    assert unlock.key?("raw"), "UNLOCK must be captured"
    assert_equal framed_payload("0"), unlock["raw"]
    refute result.key?(SIGN_RPC), "sign must not run after set-text failure"
  end

  def test_get_text_raise_still_unlocks_and_skips_sign
    note_ien = "6"
    body_line = note_text.lines.first.to_s.chomp
    client = ScriptedClient.new(
      flow_steps(
        { rpc: CREATE_RPC, raw: note_ien },
        { rpc: LOCK_RPC, raw: "0" },
        { rpc: SET_TEXT_RPC, raw: "#{note_ien}^1^1" },
        { rpc: GET_TEXT_RPC, raise: RuntimeError, message: "GET failed" },
        { rpc: UNLOCK_RPC, raw: "0" }
      ),
      framer: method(:framed_payload)
    )
    RpmsRpc.configure { |cfg| cfg.client = client }

    result = run_flow(client, esig: "synthetic-esig-77")

    assert result[GET_TEXT_RPC].key?("error")
    unlock = result[UNLOCK_RPC]
    refute_nil unlock
    assert unlock.key?("raw")
    refute result.key?(SIGN_RPC)
  end

  def test_driver_read_entries_empty_on_write_run
    assert RpmsRpc::WireCapture.respond_to?(:driver_read_entries),
           "WireCapture.driver_read_entries missing"

    assert_equal [], RpmsRpc::WireCapture.driver_read_entries(writes: true, only: "", cite_only: [])
    assert_equal [], RpmsRpc::WireCapture.driver_read_entries(
      writes: true, only: "ORQQVI VITALS", cite_only: [ "ORQQPL LIST" ]
    )
  end

  def test_driver_read_entries_selects_live_reads_when_not_writing
    live = RpmsRpc::WireCapture::CATALOG.select(&:live?)
    expected = live.map(&:rpc).sort
    got = RpmsRpc::WireCapture.driver_read_entries(writes: false, only: "", cite_only: [])
    assert_equal expected, got.map(&:rpc).sort

    only_rpc = "ORQQVI VITALS"
    filtered = RpmsRpc::WireCapture.driver_read_entries(writes: nil, only: only_rpc, cite_only: [])
    assert_equal [ only_rpc ], filtered.map(&:rpc)

    cite = "ORQQPL LIST"
    without_cited = RpmsRpc::WireCapture.driver_read_entries(
      writes: false, only: "", cite_only: [ cite ]
    )
    refute_includes without_cited.map(&:rpc), cite
  end

  def test_wire_capture_driver_calls_driver_read_entries
    path = File.expand_path("../../bin/wire_capture_driver.rb", __dir__)
    src = File.binread(path).force_encoding(Encoding::UTF_8)
    assert_match(/\bdriver_read_entries\b/, src,
                 "bin/wire_capture_driver.rb must select read captures via driver_read_entries")
  end

  def test_write_connect_host_returns_resolved_loopback_or_nil
    assert RpmsRpc::WireCapture.respond_to?(:write_connect_host),
           "WireCapture.write_connect_host missing (#564)"
    assert_equal "127.0.0.1",
                 RpmsRpc::WireCapture.write_connect_host(
                   host: "broker.example",
                   resolver: ->(_name) { [ "127.0.0.1" ] }
                 )
    assert_nil RpmsRpc::WireCapture.write_connect_host(
      host: "broker.example",
      resolver: ->(_name) { [ "10.0.0.5" ] }
    )
  end

  def test_wire_capture_driver_connects_via_write_connect_host_not_raw_name
    path = File.expand_path("../../bin/wire_capture_driver.rb", __dir__)
    src = File.binread(path).force_encoding(Encoding::UTF_8)
    assert_match(/\bwrite_connect_host\b/, src,
                 "bin/wire_capture_driver.rb must resolve the broker via write_connect_host")
    refute_match(/RpmsRpc::CiaClient\.new\(\s*host:\s*host\b/, src,
                 "CiaClient must receive write_connect_host's resolved address, not the raw BROKER_HOST name")
  end

  def test_fixture_entries_returns_write_catalog_only_when_writes_enabled
    assert RpmsRpc::WireCapture.respond_to?(:fixture_entries),
           "WireCapture.fixture_entries missing (#564)"
    write_rpcs = RpmsRpc::WireCapture::CATALOG.select(&:write?).map(&:rpc).sort
    got = RpmsRpc::WireCapture.fixture_entries(writes: true, only: nil).map(&:rpc).sort
    assert_equal write_rpcs, got
    refute_includes got, "ORQQVI VITALS"
  end

  def test_fixture_entries_returns_read_and_routine_cite_catalog_when_not_writing
    expected = RpmsRpc::WireCapture::CATALOG.reject(&:write?).map(&:rpc).sort
    got = RpmsRpc::WireCapture.fixture_entries(writes: false, only: nil).map(&:rpc).sort
    assert_equal expected, got
    refute_includes got, "TIU CREATE RECORD"
    assert_includes got, "ORWPT CWAD"
    assert_includes got, "ORQQVI VITALS"
  end

  def test_fixture_entries_honors_only_when_narrowing_read_catalog
    only_rpc = "ORQQVI VITALS"
    got = RpmsRpc::WireCapture.fixture_entries(writes: false, only: only_rpc)
    assert_equal [ only_rpc ], got.map(&:rpc)
  end

  def test_fixture_entries_treats_blank_only_as_unset
    full = RpmsRpc::WireCapture.fixture_entries(writes: false, only: nil).map(&:rpc).sort
    [ "", " ", "  " ].each do |blank|
      got = RpmsRpc::WireCapture.fixture_entries(writes: false, only: blank).map(&:rpc).sort
      assert_equal full, got, "only #{blank.inspect} must behave like unset"
    end
  end

  def test_wire_rake_fixture_loop_uses_fixture_entries
    path = File.expand_path("../../lib/tasks/wire.rake", __dir__)
    src = File.binread(path).force_encoding(Encoding::UTF_8)
    assert_match(/\bfixture_entries\b/, src,
                 "lib/tasks/wire.rake must iterate catalog entries via fixture_entries")
    refute_match(/WireCapture::CATALOG\.each\b/, src,
                 "wire.rake must not iterate the full catalog directly for fixture writes")
  end

  ESIG_SYNTHETIC = "synthetic-esig-77"
  READ_BACK_NOTE_IEN = "10"
  GET_TEXT_CIA_FRAME = "8"
  TIU_FLOW_RPCS = [
    CREATE_RPC, LOCK_RPC, SET_TEXT_RPC, GET_TEXT_RPC, UNLOCK_RPC, SIGN_RPC
  ].freeze

  def tiu_get_fixture_raw
    path = File.expand_path("../fixtures/wire_captures/tiu-get-record-text.yml", __dir__)
    RpmsRpc::WireCapture::Fixture.load_file(path).raw_return
  end

  def tiu_get_read_back_header(row_sep)
    [
      "LOCAL TITLE: Progress Note                                      ",
      "STANDARD TITLE: PRIMARY CARE PROGRESS NOTE                      ",
      "DATE OF NOTE: NOV 05, 2026@04:23:54  ENTRY DATE: NOV 05, 2026@04:23:54      ",
      "      AUTHOR: PROVIDER,TEST        EXP COSIGNER:                           ",
      "     URGENCY:                            STATUS: UNSIGNED                      "
    ].join(row_sep)
  end

  def tiu_get_framed(body_rows, row_sep: "\r")
    payload = ([ tiu_get_read_back_header(row_sep), "" ] + body_rows).join(row_sep) + row_sep
    "#{GET_TEXT_CIA_FRAME}\x00#{payload}"
  end

  def wrapped_note_body_rows
    note_ien = "1"
    RpmsRpc.mock! { |m| m.seed_scalar(:tiu_set_document_text, note_ien, "#{note_ien}^1^1") }
    RpmsRpc::ProgressNote.update_text(note_ien, note_text)
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == SET_TEXT_RPC }
    flunk "TIU SET DOCUMENT TEXT was not called" unless call

    tiux = call[:params][1]
    tiux.select { |k, _| k.is_a?(Array) && k.first == "TEXT" }
        .sort_by { |k, _| k[1] }
        .map(&:last)
  ensure
    RpmsRpc.reset!
  end

  def assert_get_read_back_evidence?(raw, message)
    entry = get_catalog_entry
    assert RpmsRpc::WireCapture.write_evidence?(
      entry, raw, note_body: note_text, note_ien: READ_BACK_NOTE_IEN
    ), message
  end

  def refute_get_read_back_evidence?(raw, message)
    entry = get_catalog_entry
    refute RpmsRpc::WireCapture.write_evidence?(
      entry, raw, note_body: note_text, note_ien: READ_BACK_NOTE_IEN
    ), message
  end

  def assert_flow_stops_after_getvisit(client, visit_raw:, result: nil)
    result ||= run_flow(client, esig: ESIG_SYNTHETIC)
    assert_equal [ GETVISIT_RPC ], client.calls.map { |c| c[:rpc] },
                 "only BEHOENCX GETVISIT must run when the visit patient gate fails"
    TIU_FLOW_RPCS.each do |rpc|
      capture = result[rpc]
      refute capture.is_a?(Hash) && capture.key?("raw"),
             "#{rpc} must not record raw when create is gated off"
    end
    assert_getvisit_capture(result, raw: visit_raw) if visit_raw
    result
  end

  def wrapped_read_back_payload(note_ien)
    body_lines = nil
    RpmsRpc.mock! { |m| m.seed_scalar(:tiu_set_document_text, note_ien, "#{note_ien}^1^1") }
    RpmsRpc::ProgressNote.update_text(note_ien, note_text)
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == SET_TEXT_RPC }
    flunk "TIU SET DOCUMENT TEXT was not called" unless call

    tiux = call[:params][1]
    body_lines = tiux.select { |k, _| k.is_a?(Array) && k.first == "TEXT" }
                     .sort_by { |k, _| k[1] }
                     .map(&:last)
    header = [
      "LOCAL TITLE: Progress Note",
      "STANDARD TITLE: Progress Note",
      "DATE OF NOTE: 3251105",
      "AUTHOR: PROVIDER,TEST",
      "URGENCY: routine"
    ].join("\n")
    "#{header}\n\n#{body_lines.join("\n")}\n"
  ensure
    RpmsRpc.reset!
  end

  def get_catalog_entry
    RpmsRpc::WireCapture::CATALOG.find { |e| e.rpc == GET_TEXT_RPC }
  end

  def assert_read_back_fails_write_evidence?(raw_payload, note_ien)
    entry = get_catalog_entry
    refute RpmsRpc::WireCapture.write_evidence?(
      entry, framed_payload(raw_payload), note_body: note_text, note_ien: note_ien
    ), "read-back fixture must fail write_evidence? so sign must not run"
  end

  def assert_read_back_passes_write_evidence?(raw_payload, note_ien)
    entry = get_catalog_entry
    assert RpmsRpc::WireCapture.write_evidence?(
      entry, framed_payload(raw_payload), note_body: note_text, note_ien: note_ien
    ), "read-back must pass write_evidence? before sign"
  end

  def test_sign_skipped_when_read_back_has_header_but_no_note_body
    note_ien = "10"
    header_only = [
      "LOCAL TITLE: Progress Note",
      "STANDARD TITLE: PRIMARY CARE PROGRESS NOTE",
      "     URGENCY:   STATUS: UNSIGNED"
    ].join("\n")
    assert_read_back_fails_write_evidence?(header_only, note_ien)

    client = ScriptedClient.new(
      flow_steps(
        { rpc: CREATE_RPC, raw: note_ien },
        { rpc: LOCK_RPC, raw: "0" },
        { rpc: SET_TEXT_RPC, raw: "#{note_ien}^1^1" },
        { rpc: GET_TEXT_RPC, raw: header_only },
        { rpc: UNLOCK_RPC, raw: "0" }
      ),
      framer: method(:framed_payload)
    )
    RpmsRpc.configure { |cfg| cfg.client = client }

    result = run_flow(client, esig: ESIG_SYNTHETIC)

    refute result.key?(SIGN_RPC),
           "TIU SIGN RECORD must not run when GET read-back fails write_evidence? (header only, no body)"
  end

  def test_sign_skipped_when_set_text_reports_failure
    note_ien = "10"
    client = ScriptedClient.new(
      flow_steps(
        { rpc: CREATE_RPC, raw: note_ien },
        { rpc: LOCK_RPC, raw: "0" },
        { rpc: SET_TEXT_RPC, raw: "0^0^0^Invalid" },
        { rpc: UNLOCK_RPC, raw: "0" }
      ),
      framer: method(:framed_payload)
    )
    RpmsRpc.configure { |cfg| cfg.client = client }

    result = run_flow(client, esig: ESIG_SYNTHETIC)

    refute result.key?(SIGN_RPC),
           "TIU SIGN RECORD must not run when update_text success is false"
    refute result.key?(GET_TEXT_RPC),
           "read-back must not run after set-text failure when sign is gated on proven read-back"
  end

  def test_sign_skipped_when_unlock_does_not_return_zero
    note_ien = "10"
    read_back = wrapped_read_back_payload(note_ien)
    assert_read_back_passes_write_evidence?(read_back, note_ien)

    client = ScriptedClient.new(
      flow_steps(
        { rpc: CREATE_RPC, raw: note_ien },
        { rpc: LOCK_RPC, raw: "0" },
        { rpc: SET_TEXT_RPC, raw: "#{note_ien}^1^1" },
        { rpc: GET_TEXT_RPC, raw: read_back },
        { rpc: UNLOCK_RPC, raw: "1^x" }
      ),
      framer: method(:framed_payload)
    )
    RpmsRpc.configure { |cfg| cfg.client = client }

    result = run_flow(client, esig: ESIG_SYNTHETIC)

    refute result.key?(SIGN_RPC),
           "TIU SIGN RECORD must not run when unlock did not return ERR=0"
  end

  def test_sign_runs_after_proven_read_back_unlock_and_set_success
    note_ien = "10"
    read_back = wrapped_read_back_payload(note_ien)
    assert_read_back_passes_write_evidence?(read_back, note_ien)

    client = ScriptedClient.new(
      flow_steps(
        { rpc: CREATE_RPC, raw: note_ien },
        { rpc: LOCK_RPC, raw: "0" },
        { rpc: SET_TEXT_RPC, raw: "#{note_ien}^1^1" },
        { rpc: GET_TEXT_RPC, raw: read_back },
        { rpc: UNLOCK_RPC, raw: "0" },
        { rpc: SIGN_RPC, raw: "0" }
      ),
      framer: method(:framed_payload)
    )
    RpmsRpc.configure { |cfg| cfg.client = client }

    result = run_flow(client, esig: ESIG_SYNTHETIC)

    assert result.key?(SIGN_RPC),
           "TIU SIGN RECORD must run when create, set-text, read-back evidence, and unlock all succeed"
  end

  def test_lock_raise_records_error_and_attempts_unlock_without_later_steps
    note_ien = "6"
    client = ScriptedClient.new(
      flow_steps(
        { rpc: CREATE_RPC, raw: note_ien },
        { rpc: LOCK_RPC, raise: IOError, message: "lock transport failed" },
        { rpc: UNLOCK_RPC, raw: "0" }
      ),
      framer: method(:framed_payload)
    )
    RpmsRpc.configure { |cfg| cfg.client = client }

    result = run_flow(client, esig: ESIG_SYNTHETIC)

    lock = result[LOCK_RPC]
    assert lock.is_a?(Hash) && lock.key?("error"), "lock raise must be recorded as error"
    assert_match(/IOError/i, lock["error"])

    assert result.key?(UNLOCK_RPC),
           "a lock that raises must still attempt TIU UNLOCK RECORD"
    refute result.key?(SET_TEXT_RPC)
    refute result.key?(GET_TEXT_RPC)
    refute result.key?(SIGN_RPC)
  end

  def test_run_calls_getvisit_before_create_when_visit_patient_matches_dfn
    client = ScriptedClient.new(
      flow_steps({ rpc: CREATE_RPC, raw: "0^synthetic create refused" }),
      framer: method(:framed_payload)
    )
    RpmsRpc.configure { |cfg| cfg.client = client }

    run_flow(client, esig: nil)

    assert_equal 2, client.calls.length
    assert_equal GETVISIT_RPC, client.calls[0][:rpc]
    assert_equal [ flow_class::VISIT_IEN ], client.calls[0][:params]
    assert_equal CREATE_RPC, client.calls[1][:rpc]
  end

  def test_run_skips_tiu_when_getvisit_patient_does_not_match_dfn
    visit_raw = "3^3260902.12^E^2^^0"
    client = ScriptedClient.new(
      [ visit_step(raw: visit_raw) ],
      framer: method(:framed_payload)
    )
    RpmsRpc.configure { |cfg| cfg.client = client }

    assert_flow_stops_after_getvisit(client, visit_raw: visit_raw)
  end

  def test_run_skips_tiu_when_getvisit_patient_piece_blank
    visit_raw = "3^3260902.12^E^^^0"
    client = ScriptedClient.new(
      [ visit_step(raw: visit_raw) ],
      framer: method(:framed_payload)
    )
    RpmsRpc.configure { |cfg| cfg.client = client }

    assert_flow_stops_after_getvisit(client, visit_raw: visit_raw)
  end

  def test_run_skips_tiu_when_getvisit_reply_empty
    visit_raw = ""
    client = ScriptedClient.new(
      [ visit_step(raw: visit_raw) ],
      framer: method(:framed_payload)
    )
    RpmsRpc.configure { |cfg| cfg.client = client }

    assert_flow_stops_after_getvisit(client, visit_raw: visit_raw)
  end

  def test_run_skips_tiu_when_getvisit_raises
    client = ScriptedClient.new(
      [ { rpc: GETVISIT_RPC, raise: RuntimeError, message: "GETVISIT transport failed" } ],
      framer: method(:framed_payload)
    )
    RpmsRpc.configure { |cfg| cfg.client = client }

    result = run_flow(client, esig: ESIG_SYNTHETIC)
    assert_equal [ GETVISIT_RPC ], client.calls.map { |c| c[:rpc] }
    TIU_FLOW_RPCS.each do |rpc|
      refute result[rpc].is_a?(Hash) && result[rpc].key?("raw"),
             "#{rpc} must not run when GETVISIT raises"
    end
  end

  def test_run_skips_tiu_when_getvisit_patient_is_zero_padded
    visit_raw = "3^3260902.12^E^04^^0"
    client = ScriptedClient.new(
      [ visit_step(raw: visit_raw) ],
      framer: method(:framed_payload)
    )
    RpmsRpc.configure { |cfg| cfg.client = client }

    assert_flow_stops_after_getvisit(client, visit_raw: visit_raw)
  end

  def test_run_skips_tiu_when_getvisit_patient_has_leading_space
    visit_raw = "3^3260902.12^E^ 4^^0"
    client = ScriptedClient.new(
      [ visit_step(raw: visit_raw) ],
      framer: method(:framed_payload)
    )
    RpmsRpc.configure { |cfg| cfg.client = client }

    assert_flow_stops_after_getvisit(client, visit_raw: visit_raw)
  end

  def test_write_evidence_read_back_requires_exact_row_grammar
    canonical = wrapped_note_body_rows
    first = note_text.lines.first.chomp
    long = note_text.lines[1].chomp

    assert_get_read_back_evidence?(tiu_get_fixture_raw,
                                   "committed live GET fixture must remain evidence")

    refute_get_read_back_evidence?(
      tiu_get_framed([ "Syntheticpilot note for wire capture." ] + canonical.drop(1)),
      "space removed inside a body row must not pass"
    )
    refute_get_read_back_evidence?(
      tiu_get_framed([ "Synthetic  pilot note for wire capture." ] + canonical.drop(1)),
      "extra space inside a body row must not pass"
    )
    refute_get_read_back_evidence?(
      tiu_get_framed([ first, "This synthetic clinical-neutral sentence exists so wire capture wraps a",
                       " progress-note line." ]),
      "leading space on a continuation row must not pass"
    )
    refute_get_read_back_evidence?(
      tiu_get_framed(canonical + [ "Extra synthetic row." ]),
      "extra body row after the note must not pass"
    )
    refute_get_read_back_evidence?(
      tiu_get_framed([ "Extra synthetic row." ] + canonical),
      "extra body row before the note must not pass"
    )
    refute_get_read_back_evidence?(
      tiu_get_framed(canonical.take(2) + [ "Extra synthetic row." ] + canonical.drop(2)),
      "extra body row between note lines must not pass"
    )
    bad_rows = canonical.dup
    bad_rows[-1] = bad_rows[-1].sub(/\.\z/, "")
    refute_get_read_back_evidence?(
      tiu_get_framed(bad_rows),
      "missing trailing punctuation on a note line must not pass"
    )
    over = "x" * (RpmsRpc::ProgressNote::WRAP_WIDTH + 1)
    refute_get_read_back_evidence?(
      tiu_get_framed([ first, over ]),
      "body row over WRAP_WIDTH must not pass"
    )

    alt_wrap = [
      first,
      "This synthetic clinical-neutral sentence exists so wire capture",
      "wraps a progress-note line."
    ]
    assert_get_read_back_evidence?(tiu_get_framed(alt_wrap),
                                   "alternate soft wrap at a different space must pass")

    wrap_w = RpmsRpc::ProgressNote::WRAP_WIDTH
    hard_row1 = long.byteslice(0, wrap_w)
    hard_row2 = long.byteslice(wrap_w, long.bytesize - wrap_w)
    assert_equal long, hard_row1 + hard_row2
    refute hard_row1.end_with?(" "), "hard_row1 must not end with a space (hard cut)"
    refute hard_row2.start_with?(" "), "hard_row2 must not start with a space (hard cut)"
    hard_body = [ first, hard_row1, hard_row2 ]
    assert_get_read_back_evidence?(tiu_get_framed(hard_body),
                                   "hard-cut wrap with bare \\r rows must pass")
    assert_get_read_back_evidence?(tiu_get_framed(hard_body, row_sep: "\r\n"),
                                   "hard-cut wrap with \\r\\n rows must pass")
  end
end
