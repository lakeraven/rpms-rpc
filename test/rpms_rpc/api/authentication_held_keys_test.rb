# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/cia_client"
require "rpms_rpc/version"
require "rpms_rpc/api/authentication"

# Authentication.held_keys asks ORWU NPHASKEY once per named security key for
# the signed-on DUZ, with OR CPRS GUI CHART bound for the batch (rpms-rpc#521).
class RpmsRpc::AuthenticationHeldKeysTest < Minitest::Test
  EOD = RpmsRpc::Client::EOD

  SYNTHETIC_DUZ = "900001"
  START_CONTEXT = "CIAV VUECENTRIC"
  HELD_CONTEXT = "OR CPRS GUI CHART"

  ASKED = %w[SYNKEYA SYNKEYB SYNKEYC SYNKEYD SYNKEYNOSUCH].freeze
  HELD_FLAGS = %w[1 1 1 1 0].freeze

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
    c.set_authenticated(SYNTHETIC_DUZ)
    c.create_context(START_CONTEXT)
    c
  end

  def configure(reads)
    RpmsRpc.configure { |c| c.client = cia_client(reads) }
  end

  def nphaskey_reads(flags)
    flags.map { |flag| "1\x00#{flag}#{EOD}" }
  end

  def teardown
    RpmsRpc.reset!
  end

  def test_replies_map_to_the_held_subset_in_order
    configure(nphaskey_reads(HELD_FLAGS))

    assert_equal %w[SYNKEYA SYNKEYB SYNKEYC SYNKEYD], RpmsRpc::Authentication.held_keys(ASKED)
  end

  def test_one_orwu_nphaskey_per_non_blank_name_carrying_duz_and_key
    asked = ASKED.first(2)
    configure(nphaskey_reads(%w[1 0]))

    RpmsRpc::Authentication.held_keys(asked)

    assert_equal 2, @socket.writes.size
    asked.each_with_index do |name, i|
      frame = @socket.writes[i]
      assert_includes frame, "ORWU NPHASKEY", "frame #{i}"
      refute_includes frame, "CIAVCXUS HASKEYS", "frame #{i}"
      assert_includes frame, SYNTHETIC_DUZ, "frame #{i}"
      assert_includes frame, name, "frame #{i}"
    end
    refute_includes @socket.writes.first, asked.join("^")
  end

  # N keys: N ORWU NPHASKEY round trips while OR CPRS GUI CHART is bound, then restore.
  # Over CIA bind and restore are client-side (CTX on frames), so @socket.writes holds N frames.
  def test_frame_count_for_n_keys_is_n_nphaskey_plus_bind_and_restore
    asked = ASKED.first(3)
    n = asked.size
    configure(nphaskey_reads(%w[1 1 0]))

    client = RpmsRpc.client
    assert_equal START_CONTEXT, client.current_context

    RpmsRpc::Authentication.held_keys(asked)

    nphaskey = @socket.writes.count { |w| w.include?("ORWU NPHASKEY") }
    assert_equal n, nphaskey
    refute @socket.writes.any? { |w| w.include?("CIAVCXUS HASKEYS") }
    assert_equal n, @socket.writes.size,
                 "for #{n} keys: #{n} ORWU NPHASKEY + 1 bind + 1 restore " \
                 "(#{n} CIA frame(s); bind and restore do not add separate frames)"
    assert_equal START_CONTEXT, client.current_context, "caller context is restored afterward"
    @socket.writes.each do |frame|
      assert_includes frame, HELD_CONTEXT, "each NPHASKEY runs under OR CPRS GUI CHART"
    end
  end

  def test_a_refused_nphaskey_returns_nil
    configure([
      "1\x001#{EOD}",
      "1\x01Access denied for remote procedure.#{EOD}"
    ])

    assert_nil RpmsRpc::Authentication.held_keys(ASKED.first(2))
  end

  def test_an_empty_nphaskey_reply_returns_nil
    configure([ "1\x00#{EOD}", "1\x001#{EOD}" ])

    assert_nil RpmsRpc::Authentication.held_keys(ASKED.first(2))
  end

  def test_an_answer_other_than_0_or_1_returns_nil
    configure([ "1\x001#{EOD}", "1\x002#{EOD}" ])

    assert_nil RpmsRpc::Authentication.held_keys(ASKED.first(2))
  end

  def test_holding_none_is_an_empty_list
    configure(nphaskey_reads(%w[0 0]))

    assert_equal [], RpmsRpc::Authentication.held_keys(%w[SYNKEYA SYNKEYB])
  end

  def test_no_signed_on_duz_returns_nil_and_sends_no_nphaskey
    c = RpmsRpc::CiaClient.new
    @socket = FakeSocket.new([ "1\x000#{EOD}" ])
    c.instance_variable_set(:@socket, @socket)
    c.instance_variable_set(:@connected, true)
    c.instance_variable_set(:@timeout, 1)
    c.instance_variable_set(:@seq, 0)
    c.instance_variable_set(:@session_uid, "1")
    c.instance_variable_set(:@current_context, START_CONTEXT)
    RpmsRpc.configure { |cfg| cfg.client = c }

    result = RpmsRpc::Authentication.held_keys([ "SYNKEYA" ])
    assert_empty @socket.writes, "must not send ORWU NPHASKEY without a signed-on DUZ"
    assert_nil result
  end

  def test_empty_names_send_nothing
    configure([])

    assert_equal [], RpmsRpc::Authentication.held_keys([])
    assert_equal [], RpmsRpc::Authentication.held_keys([ "", "  ", nil ])
    assert_empty @socket.writes
  end

  def test_names_the_routine_would_misread_are_refused
    configure([])

    assert_raises(ArgumentError) { RpmsRpc::Authentication.held_keys([ "SYN^KEY" ]) }
    assert_raises(ArgumentError) { RpmsRpc::Authentication.held_keys([ "@SYN BADKEY" ]) }
    assert_empty @socket.writes
  end
end
