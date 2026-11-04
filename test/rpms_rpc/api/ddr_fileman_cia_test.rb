# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/cia_client"
require "rpms_rpc/api/ddr_fileman"

# DdrFileman.gets_entry with several fields over the CIA broker returns one
# result per field (rpms-rpc#333).
#
# DDR GETS ENTRY DATA is return type 2, ARRAY (bcer-9.0 #8994:
# "DDR GETS ENTRY DATA^GETSC^DDR2^2^R"). GETSC^DDR2 sets one node per row:
# "[Data]", then FILE^IENS^FIELD^INTERNAL^EXTERNAL per field, the IENS
# without its trailing comma (DDR2.m:29-40). The CIA broker writes each row
# followed by CR (CIANBACT.m DATAOUT/OUT, `W @X,EOL,!` with EOL=$C(13)).
#
# Before #195 (627c67c) CiaClient#call_rpc returned printable(raw): every
# separator became a space, so the reply parsed as ONE row and every later
# field was glued into the first field's external value - the run-together
# line #333 reports from rpms-rpc 0f0bc6e on the 2026-09-30 build.
#
# The replies below are RECORDED, not built from the routine text:
# yotta-1016 (bcer-9.0-20261015-46dd047-ydb), CIA on 9100 over an SSM port
# forward, 2026-10-16, persona SYS123, rpms-rpc f85d76e. Each is the reply as
# read up to the EOD terminator: the one-byte sequence echo, the \x00 data
# ack, then the CR-terminated rows (evidence: the 2026-10-16 comment on #333).
class RpmsRpc::DdrFilemanCiaTest < Minitest::Test
  EOD = RpmsRpc::Client::EOD

  # gets_entry(file: 2, iens: "4,", fields: ".01;.02;.03", flags: "IE")
  PATIENT_REPLY = "6\x00[Data]\r2^4^.01^DEMO,PATIENT ONE^DEMO,PATIENT ONE\r" \
                  "2^4^.02^F^FEMALE\r2^4^.03^3010101^01/01/2001\r"

  # gets_entry(file: 200, iens: "4,", fields: ".01;1;4", flags: "IE")
  USER_REPLY = "7\x00[Data]\r200^4^.01^MANAGER,SYSTEM^MANAGER,SYSTEM\r" \
               "200^4^1^SM^SM\r200^4^4^M^MALE\r"

  class FakeSocket
    attr_reader :writes

    def initialize(reads)
      @reads = reads.dup
      @writes = []
    end

    def recv(_n) = @reads.empty? ? "" : @reads.shift
    def write(str) = (@writes << str) && str.bytesize
    def flush; end
    def close = @closed = true
    def closed? = !!@closed
    def setsockopt(*); end
  end

  # The recorded reply, answering the request whose sequence number it echoes.
  def replay(reply)
    c = RpmsRpc::CiaClient.new
    c.instance_variable_set(:@socket, FakeSocket.new([ reply + EOD ]))
    c.instance_variable_set(:@connected, true)
    c.instance_variable_set(:@timeout, 1)
    c.instance_variable_set(:@seq, Integer(reply[0]) - 1)
    c.instance_variable_set(:@session_uid, "1")
    RpmsRpc.configure { |cfg| cfg.client = c }
  end

  def teardown
    RpmsRpc.reset!
  end

  def test_recorded_patient_reply_returns_each_field
    replay(PATIENT_REPLY)

    result = RpmsRpc::DdrFileman.gets_entry(file: "2", iens: "4,", fields: ".01;.02;.03", flags: "IE")

    assert_equal({
      fields: {
        ".01" => { internal: "DEMO,PATIENT ONE", external: "DEMO,PATIENT ONE" },
        ".02" => { internal: "F", external: "FEMALE" },
        ".03" => { internal: "3010101", external: "01/01/2001" }
      },
      error: false,
      malformed: false
    }, result)
  end

  def test_recorded_user_reply_returns_each_field
    replay(USER_REPLY)

    result = RpmsRpc::DdrFileman.gets_entry(file: "200", iens: "4,", fields: ".01;1;4", flags: "IE")

    assert_equal({
      fields: {
        ".01" => { internal: "MANAGER,SYSTEM", external: "MANAGER,SYSTEM" },
        "1" => { internal: "SM", external: "SM" },
        "4" => { internal: "M", external: "MALE" }
      },
      error: false,
      malformed: false
    }, result)
  end

  # rpms-rpc#540: visit comment hazards over the real CiaClient row split must not
  # parse as a clean gets_entry (stray or altered) before Wellness can resend text.
  VISIT_FILE = "9002011"
  VISIT_IEN = "8840"
  SYNTH_PATIENT = "990540"

  def visit_gets_reply(seq, *field_rows)
    "#{seq}\x00[Data]\r#{field_rows.join("\r")}\r"
  end

  def visit_row(field, internal, external = internal)
    "#{VISIT_FILE}^#{VISIT_IEN}^#{field}^#{internal}^#{external}"
  end

  def test_gets_entry_over_cia_marks_stray_when_stored_comment_splits_a_bracket_line
    rows = [
      visit_row(".08", SYNTH_PATIENT, "PATIENT,SYNTH"),
      visit_row("1112", "", ""),
      visit_row("1601", "Alcohol baseline\r[follow-up later]", "NEGATIVE"),
      visit_row("1403", "N", "NEGATIVE")
    ]
    replay(visit_gets_reply("3", *rows))

    result = RpmsRpc::DdrFileman.gets_entry(
      file: VISIT_FILE, iens: "#{VISIT_IEN},", fields: ".08;1112;1601;1403", flags: "I"
    )

    assert result[:stray] || result[:altered],
      "a bracket-shaped fragment from an embedded CR in stored 1601 must not read as clean"
    refute_equal "Alcohol baseline\r[follow-up later]", result.dig(:fields, "1601", :internal)
  end

  def test_gets_entry_over_cia_marks_altered_when_stored_comment_contains_lone_recordset_end_byte
    rows = [
      visit_row(".08", SYNTH_PATIENT, "PATIENT,SYNTH"),
      visit_row("1601", "Alcohol part one\r\n\x1f\r\n[part two]", "NEGATIVE")
    ]
    replay(visit_gets_reply("4", *rows))

    result = RpmsRpc::DdrFileman.gets_entry(
      file: VISIT_FILE, iens: "#{VISIT_IEN},", fields: ".08;1601", flags: "I"
    )

    assert result[:altered],
      "a lone \\x1f dropped by CiaClient must surface as altered on gets_entry"
  end

  def test_gets_entry_over_cia_marks_altered_when_stored_comment_ends_with_cr_before_reply_terminator
    rows = [
      visit_row(".08", SYNTH_PATIENT, "PATIENT,SYNTH"),
      visit_row("1601", "Alcohol baseline", "NEGATIVE")
    ]
    replay(visit_gets_reply("5", *rows) + "\r")

    result = RpmsRpc::DdrFileman.gets_entry(
      file: VISIT_FILE, iens: "#{VISIT_IEN},", fields: ".08;1601", flags: "I"
    )

    assert result[:altered],
      "an extra trailing row break after the last field row must mark the reply altered"
  end
end
