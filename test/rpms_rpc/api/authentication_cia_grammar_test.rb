# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/cia_client"
require "rpms_rpc/version"
require "rpms_rpc/api/authentication"

# The Authentication facade parses XUS AV CODE by LINE POSITION. A CIA
# client's call_rpc returns a printable String — the raw reply's sequence
# echo, ack byte and CR/CRLF line separators flattened to spaces — so a
# line-positional parser handed that String reads CHARACTERS as fields:
# a reply beginning with sequence echo "2" + ACK parses as DUZ 2, error
# code 0, success. A plausible WRONG identity, minted from framing bytes.
#
# The facade must consume replies through the transport's reply grammar
# (Client#call_rpc_lines), never through character indexing.
class RpmsRpc::AuthenticationCiaGrammarTest < Minitest::Test
  EOD = RpmsRpc::Client::EOD

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

  def cia_client(reads)
    c = RpmsRpc::CiaClient.new
    c.instance_variable_set(:@socket, FakeSocket.new(reads))
    c.instance_variable_set(:@connected, true)
    c.instance_variable_set(:@timeout, 1)
    c.instance_variable_set(:@seq, 0)
    c.instance_variable_set(:@session_uid, "1")
    c
  end

  def teardown
    RpmsRpc.reset!
  end

  # VALIDAV^XUSRB rejected the pair: RET(0)=0 (DUZ), "Invalid A/V code.".
  # Wire form: 1-byte sequence echo, \x00 ack, CRLF-separated lines. The
  # character parse turns the "2" sequence echo into DUZ 2 and the ack into
  # error code 0 — a successful sign-on as user 2, from a REJECTION.
  def test_a_cia_rejection_is_not_misparsed_into_a_plausible_duz
    RpmsRpc.configure do |c|
      c.client = cia_client([
        "2\x00OK#{EOD}",                                          # XUS SIGNON SETUP
        "2\x000\r\n0\r\n0\r\nInvalid A/V code.\r\n0\r\n0#{EOD}",  # XUS AV CODE — DUZ 0
        "2\x00IRRELEVANT#{EOD}"                                    # would-be XUS GET USER INFO
      ])
    end

    result = RpmsRpc::Authentication.authenticate(access_code: "AAA", verify_code: "BBB")

    refute result[:success],
      "a CIA rejection reply (DUZ 0) was parsed character-by-character into a success"
    assert_nil result[:duz],
      "the sequence echo byte was minted into a DUZ — a plausible wrong identity"
  end

  # The same grammar, accepted: DUZ 301 on line 0 must come back as 301 —
  # not as the sequence echo character, and not nil.
  def test_a_cia_acceptance_parses_duz_from_the_reply_lines
    RpmsRpc.configure do |c|
      c.client = cia_client([
        "2\x00OK#{EOD}",                                            # XUS SIGNON SETUP
        "2\x00301\r\n0\r\n0\r\nGood evening\r\n0\r\n0#{EOD}",       # XUS AV CODE — DUZ 301
        "2\x00301\r\nBETA,BOB\r\nBETA,BOB\r\nDEMO SITE#{EOD}"       # XUS GET USER INFO
      ])
    end

    result = RpmsRpc::Authentication.authenticate(access_code: "AAA", verify_code: "BBB")

    assert result[:success], "a valid CIA acceptance reply failed to parse: #{result.inspect}"
    assert_equal 301, result[:duz]
    assert_equal "BETA,BOB", result[:name]
  end

  # The YDB-served broker writes reply lines with bare CR (verified live
  # 2026-09-03 — see CiaClient#session_params). The grammar parse must
  # split on it the same way session_params does.
  def test_bare_cr_line_separators_parse_the_same_as_crlf
    RpmsRpc.configure do |c|
      c.client = cia_client([
        "2\x00OK#{EOD}",
        "2\x00301\r0\r0\rGood evening\r0\r0#{EOD}",
        "2\x00301\rBETA,BOB\rBETA,BOB\rDEMO SITE#{EOD}"
      ])
    end

    result = RpmsRpc::Authentication.authenticate(access_code: "AAA", verify_code: "BBB")

    assert result[:success]
    assert_equal 301, result[:duz]
  end
end
