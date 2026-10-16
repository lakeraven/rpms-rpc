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
# without its trailing comma (DDR2.m:29-40). The CIA broker writes an ARRAY
# reply with DATAOUT^CIANBACT -> OUT("CIAD",1): the $C(0) ack, then each node
# followed by $C(13) and the device's line terminator (CIANBACT.m DATAOUT/OUT,
# `W @X,EOL,!` with EOL=$C(13)). The YottaDB broker's terminator adds nothing,
# so the rows arrive CR-separated (seen live on the CIA sign-on reply,
# 2026-09-03); a CRLF terminator (rows ending CR CR LF) is covered too.
#
# Before #195 (627c67c) CiaClient#call_rpc returned printable(raw): every
# separator became a space, so the reply parsed as ONE row and every later
# field was glued into the first field's external value - the run-together
# line #333 reports from rpms-rpc 0f0bc6e on the 2026-09-30 build.
#
# The reply bytes here are routine-cited, not a recording: no live
# multi-field CIA capture of DDR GETS ENTRY DATA exists yet.
class RpmsRpc::DdrFilemanCiaTest < Minitest::Test
  EOD = RpmsRpc::Client::EOD

  ROWS = [
    "[Data]",
    "2^1^.01^DEMOPATIENT,ONE^DEMOPATIENT,ONE",
    "2^1^.02^F^FEMALE",
    "2^1^.03^2450101^JAN 01, 1945"
  ].freeze

  EXPECTED = {
    ".01" => { internal: "DEMOPATIENT,ONE", external: "DEMOPATIENT,ONE" },
    ".02" => { internal: "F", external: "FEMALE" },
    ".03" => { internal: "2450101", external: "JAN 01, 1945" }
  }.freeze

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

  def configure_cia(body)
    c = RpmsRpc::CiaClient.new
    c.instance_variable_set(:@socket, FakeSocket.new([ "1\x00#{body}" + EOD ]))
    c.instance_variable_set(:@connected, true)
    c.instance_variable_set(:@timeout, 1)
    c.instance_variable_set(:@seq, 0)
    c.instance_variable_set(:@session_uid, "1")
    RpmsRpc.configure { |cfg| cfg.client = c }
  end

  def teardown
    RpmsRpc.reset!
  end

  def gets_entry
    RpmsRpc::DdrFileman.gets_entry(file: "2", iens: "1,", fields: ".01;.02;.03", flags: "IE")
  end

  def test_multi_field_reply_with_cr_terminated_rows_returns_each_field
    configure_cia(ROWS.map { |row| "#{row}\r" }.join)

    assert_equal({ fields: EXPECTED, error: false }, gets_entry)
  end

  def test_multi_field_reply_with_cr_crlf_terminated_rows_returns_each_field
    configure_cia(ROWS.map { |row| "#{row}\r\r\n" }.join)

    assert_equal({ fields: EXPECTED, error: false }, gets_entry)
  end
end
