# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/cia_client"
require "rpms_rpc/version"
require "rpms_rpc/api/authentication"

# Authentication.held_keys asks CIAVCXUS HASKEYS which of the named security
# keys the signed-on user holds (rpms-rpc#318).
#
# The routine (VueCentric Framework/Routines/CIAVCXUS.m:14-18):
#
#   HASKEYS(DATA,KEYS) ;EP
#    N PC
#    S DATA=""
#    F PC=1:1:$L(KEYS,U) S $P(DATA,U,PC)=$$HASKEY($P(KEYS,U,PC))
#    Q
#
# One actual, KEYS, the names joined with "^" (registry formals: DATA,KEYS;
# SINGLE VALUE). The reply is one line holding one 0/1 per name, in order;
# HASKEY (CIAVCXUS.m:8-12) answers ''$D(^XUSEC(KEY,+USR)) for USR=DUZ, the
# signed-on user.
class RpmsRpc::AuthenticationHeldKeysTest < Minitest::Test
  EOD = RpmsRpc::Client::EOD

  # The live question and reply on bcer-9.0 YottaDB over CIA, 2026-10-02,
  # signed on as a user holding the first four keys (#318).
  ASKED = %w[AGZMENU SDZSUP SDZMENU AGZVIEWSSN NOSUCHKEY].freeze
  LIVE_REPLY = "1^1^1^1^0"

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
    @socket = FakeSocket.new(reads)
    c.instance_variable_set(:@socket, @socket)
    c.instance_variable_set(:@connected, true)
    c.instance_variable_set(:@timeout, 1)
    c.instance_variable_set(:@seq, 0)
    c.instance_variable_set(:@session_uid, "1")
    c
  end

  def configure(reads)
    RpmsRpc.configure { |c| c.client = cia_client(reads) }
  end

  def teardown
    RpmsRpc.reset!
  end

  # AC1: the live reply names the four keys held, in the order asked.
  def test_the_live_reply_returns_the_keys_held
    configure([ "1\x00#{LIVE_REPLY}#{EOD}" ])

    assert_equal %w[AGZMENU SDZSUP SDZMENU AGZVIEWSSN], RpmsRpc::Authentication.held_keys(ASKED)
  end

  # AC2: one CIAVCXUS HASKEYS call, the names as ONE "^"-joined actual
  # (HASKEYS(DATA,KEYS), CIAVCXUS.m:14 pieces KEYS by U).
  def test_one_call_carries_the_names_joined_with_caret
    configure([ "1\x00#{LIVE_REPLY}#{EOD}" ])

    RpmsRpc::Authentication.held_keys(ASKED)

    assert_equal 1, @socket.writes.size, "held_keys must ask once, not once per key"
    frame = @socket.writes.first
    assert_includes frame, "CIAVCXUS HASKEYS"
    assert_includes frame, ASKED.join("^")
  end

  # AC3: a refusal (SNDERR, CIANBLIS.m:265) is nil, not [], so a consumer can
  # tell "holds none" from "could not ask".
  def test_a_refused_call_returns_nil
    configure([ "1\x01Access denied for remote procedure.#{EOD}" ])

    assert_nil RpmsRpc::Authentication.held_keys(ASKED)
  end

  # AC3: no answer at all is nil as well.
  def test_an_empty_reply_returns_nil
    configure([ "1\x00#{EOD}" ])

    assert_nil RpmsRpc::Authentication.held_keys(ASKED)
  end

  # A reply with fewer pieces than names asked cannot be read piecewise
  # (CIAVCXUS.m:17 sets one piece per name); nil rather than a guess.
  def test_a_reply_short_of_pieces_returns_nil
    configure([ "1\x001^1#{EOD}" ])

    assert_nil RpmsRpc::Authentication.held_keys(ASKED)
  end

  # A user who holds none of the keys gets [] (an answer), not nil.
  def test_holding_none_is_an_empty_list
    configure([ "1\x000^0#{EOD}" ])

    assert_equal [], RpmsRpc::Authentication.held_keys(%w[AGZMENU SDZMENU])
  end

  # AC4: an empty list asks nothing and holds nothing. Blank names are
  # dropped first: HASKEY answers 1 for an empty KEY (CIAVCXUS.m:9,
  # Q:'$L(KEY) 1), so sending one would report a key "held".
  def test_empty_names_send_nothing
    configure([])

    assert_equal [], RpmsRpc::Authentication.held_keys([])
    assert_equal [], RpmsRpc::Authentication.held_keys([ "", "  ", nil ])
    assert_empty @socket.writes
  end

  # A name containing "^" would shift every later piece (CIAVCXUS.m:17), and
  # one beginning with "@" asks a PARAMETER, not a key (CIAVCXUS.m:11).
  # Neither is a security key name; refuse before sending.
  def test_names_the_routine_would_misread_are_refused
    configure([])

    assert_raises(ArgumentError) { RpmsRpc::Authentication.held_keys([ "A^B" ]) }
    assert_raises(ArgumentError) { RpmsRpc::Authentication.held_keys([ "@CIAV DESIGN" ]) }
    assert_empty @socket.writes
  end
end
