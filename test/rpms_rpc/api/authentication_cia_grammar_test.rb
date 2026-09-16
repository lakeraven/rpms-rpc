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
  #
  # NOTE the name assertion: it reads line 1 of the SECOND reply (user_info).
  # DUZ alone is a vacuous gate — "301 0 0 Good evening".to_i == 301 forgives
  # an UNSPLIT line, so dropping bare-CR from the split would still pass a
  # DUZ-only assertion. A line-1+ field only resolves if the lines actually
  # split.
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
    assert_equal "BETA,BOB", result[:name],
      "user_info line 1 did not resolve — the reply was not split into lines"
  end

  # -- the three broker reply shapes (CIANBLIS.m: W SEQ is UNCONDITIONAL) ----
  #
  # DOACTION^CIANBLIS writes the sequence echo for EVERY reply, then branches:
  #   REPLY   $C(0) + data   (CIANBLIS.m:261)
  #   SNDERR  $C(1) + CIAERR (CIANBLIS.m:265,268)
  #   SNDEOD  seq only, no flag byte at all (CIANBLIS.m:273)
  # Stripping only "[1-9]\x00" (the REPLY flag) left the sequence echo glued
  # to line 0 for the error and no-data shapes — so a rejection minted a DUZ
  # from the sequence byte.

  # An ungated XUS AV CODE gets SNDERR "Access denied for remote procedure."
  # The seq echo "3" + \x01 must NOT parse as DUZ 3 / success. A broker-level
  # error is a typed RpcError, never a sign-on.
  def test_a_cia_snderr_reply_is_a_typed_error_not_a_minted_duz
    RpmsRpc.configure do |c|
      c.client = cia_client([
        "2\x00OK#{EOD}",                                      # XUS SIGNON SETUP
        "3\x01Access denied for remote procedure.#{EOD}"     # XUS AV CODE — SNDERR
      ])
    end

    assert_raises(RpmsRpc::Client::RpcError,
      "a CIA SNDERR reply was parsed into a sign-on instead of raising") do
      RpmsRpc::Authentication.authenticate(access_code: "AAA", verify_code: "BBB")
    end
  end

  # A seq-only SNDEOD reply (no data, no flag) must fail closed — not mint a
  # DUZ from the sequence byte "5".
  def test_a_cia_no_data_reply_does_not_mint_a_duz
    RpmsRpc.configure do |c|
      c.client = cia_client([
        "2\x00OK#{EOD}",  # XUS SIGNON SETUP
        "5#{EOD}"          # XUS AV CODE — SNDEOD, sequence echo only
      ])
    end

    result = RpmsRpc::Authentication.authenticate(access_code: "AAA", verify_code: "BBB")

    refute result[:success], "a no-data reply was parsed as a successful sign-on"
    assert_nil result[:duz], "the sequence echo byte was minted into a DUZ"
  end

  # A malformed reply whose byte after the seq echo is neither \x00 nor \x01
  # (e.g. an ACK-less "2\r\n…", or the echo concatenated onto a digit) must
  # fail closed, never parse the seq byte as a DUZ.
  def test_an_ack_less_reply_does_not_mint_a_duz
    [ "2\r\n0\r\n0\r\nInvalid A/V code.\r\n0\r\n0", "20\r\n0\r\n0\r\nInvalid\r\n0\r\n0", "2" ].each do |shape|
      RpmsRpc.configure do |c|
        c.client = cia_client([ "2\x00OK#{EOD}", "#{shape}#{EOD}" ])
      end

      result = RpmsRpc::Authentication.authenticate(access_code: "AAA", verify_code: "BBB")

      refute result[:success], "an ACK-less reply #{shape.inspect} parsed as success"
      assert_nil result[:duz], "the sequence echo of #{shape.inspect} was minted into a DUZ"
    end
  end
end
