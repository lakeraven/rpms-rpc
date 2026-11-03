# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/mappings"
require "rpms_rpc/api/authentication"

# ORWU NPHASKEY for has_security_key? must be read like held_key_flag: not
# altered, exactly one normalised data line, strictly "0" or "1" (rpms-rpc#556).
class RpmsRpc::AuthenticationHasSecurityKeyStrictTest < Minitest::Test
  SYNTHETIC_DUZ = "900001"
  SYN_KEY = "SYNKEYZ"
  NPHASKEY_RPC = RpmsRpc::DataMapper[:person_has_key].rpc_name
  CALLER_CONTEXT = "SYN APP CTX"

  def teardown
    RpmsRpc.reset!
  end

  def nphaskey_calls(mock = RpmsRpc.client)
    mock.received_calls.select { |c| c[:rpc] == NPHASKEY_RPC }
  end

  def with_nphaskey_raw_lines(lines)
    RpmsRpc.mock! do |m|
      m.seed_raw_lines(:person_has_key, SYNTHETIC_DUZ, Array(lines))
    end
  end

  def with_signed_on_nphaskey_raw_lines(lines)
    RpmsRpc.mock! do |m|
      m.set_authenticated(SYNTHETIC_DUZ)
      m.seed_raw_lines(:person_has_key, SYNTHETIC_DUZ, Array(lines))
    end
  end

  # --- contract 1: true only for unaltered, single normalised line "1" --------

  def test_has_security_key_is_true_only_when_reply_is_unaltered_single_normalised_line_one
    with_nphaskey_raw_lines([ "1" ])

    assert RpmsRpc::Authentication.has_security_key?(SYNTHETIC_DUZ, SYN_KEY)
  end

  # --- contract 2: false for every non-"1" strict shape -----------------------

  def test_has_security_key_is_false_for_reply_line_zero
    with_nphaskey_raw_lines([ "0" ])

    refute RpmsRpc::Authentication.has_security_key?(SYNTHETIC_DUZ, SYN_KEY)
  end

  def test_has_security_key_is_false_for_reply_line_two
    with_nphaskey_raw_lines([ "2" ])

    refute RpmsRpc::Authentication.has_security_key?(SYNTHETIC_DUZ, SYN_KEY)
  end

  def test_has_security_key_is_false_for_reply_line_yes
    with_nphaskey_raw_lines([ "yes" ])

    refute RpmsRpc::Authentication.has_security_key?(SYNTHETIC_DUZ, SYN_KEY)
  end

  def test_has_security_key_is_false_for_reply_line_true
    with_nphaskey_raw_lines([ "true" ])

    refute RpmsRpc::Authentication.has_security_key?(SYNTHETIC_DUZ, SYN_KEY)
  end

  def test_has_security_key_is_false_for_reply_line_leading_space_one
    with_nphaskey_raw_lines([ " 1" ])

    refute RpmsRpc::Authentication.has_security_key?(SYNTHETIC_DUZ, SYN_KEY)
  end

  def test_has_security_key_is_false_for_reply_line_trailing_space_one
    with_nphaskey_raw_lines([ "1 " ])

    refute RpmsRpc::Authentication.has_security_key?(SYNTHETIC_DUZ, SYN_KEY)
  end

  def test_has_security_key_is_false_for_empty_reply_line
    with_nphaskey_raw_lines([ "" ])

    refute RpmsRpc::Authentication.has_security_key?(SYNTHETIC_DUZ, SYN_KEY)
  end

  def test_has_security_key_is_false_when_rpc_returns_empty_string
    RpmsRpc.mock!

    refute RpmsRpc::Authentication.has_security_key?(SYNTHETIC_DUZ, SYN_KEY)
  end

  def test_has_security_key_is_false_when_rpc_returns_empty_array
    with_nphaskey_raw_lines([])

    refute RpmsRpc::Authentication.has_security_key?(SYNTHETIC_DUZ, SYN_KEY)
  end

  def test_has_security_key_is_false_for_two_line_reply_one_one
    with_nphaskey_raw_lines(%w[1 1])

    refute RpmsRpc::Authentication.has_security_key?(SYNTHETIC_DUZ, SYN_KEY)
  end

  def test_has_security_key_is_false_for_two_line_reply_one_zero
    with_nphaskey_raw_lines(%w[1 0])

    refute RpmsRpc::Authentication.has_security_key?(SYNTHETIC_DUZ, SYN_KEY)
  end

  def test_has_security_key_is_false_for_two_line_reply_zero_one
    with_nphaskey_raw_lines(%w[0 1])

    refute RpmsRpc::Authentication.has_security_key?(SYNTHETIC_DUZ, SYN_KEY)
  end

  class AlteredOneLineReplyMock < RpmsRpc::MockClient
    def call_rpc(rpc_name, *params)
      received_calls << { rpc: rpc_name, params: params, context: current_context }
      RpmsRpc::Reply.from_wire([ "1" ], altered: [ 0 ])
    end
  end

  def test_has_security_key_is_false_when_altered_reply_normalises_to_line_one
    mock = AlteredOneLineReplyMock.new
    RpmsRpc.configure { |cfg| cfg.client = mock }

    refute RpmsRpc::Authentication.has_security_key?(SYNTHETIC_DUZ, SYN_KEY)
  end

  # --- contract 3: multi-line reply must not trust the first line alone -------

  def test_has_security_key_is_false_when_first_data_line_is_one_but_reply_has_multiple_lines
    with_nphaskey_raw_lines(%w[1 0])

    refute RpmsRpc::Authentication.has_security_key?(SYNTHETIC_DUZ, SYN_KEY)
  end

  # --- contract 4: unchanged behaviour (must stay green before the fix) ---------

  def test_has_security_key_returns_false_for_nil_duz_and_sends_no_nphaskey
    RpmsRpc.mock!

    refute RpmsRpc::Authentication.has_security_key?(nil, SYN_KEY)
    assert_empty nphaskey_calls
  end

  def test_has_security_key_returns_false_for_zero_duz_and_sends_no_nphaskey
    RpmsRpc.mock!

    refute RpmsRpc::Authentication.has_security_key?(0, SYN_KEY)
    assert_empty nphaskey_calls
  end

  def test_has_security_key_returns_false_for_negative_duz_and_sends_no_nphaskey
    RpmsRpc.mock!

    refute RpmsRpc::Authentication.has_security_key?(-5, SYN_KEY)
    assert_empty nphaskey_calls
  end

  def test_has_security_key_returns_false_for_non_numeric_duz_and_sends_no_nphaskey
    RpmsRpc.mock!

    refute RpmsRpc::Authentication.has_security_key?("900001abc", SYN_KEY)
    assert_empty nphaskey_calls
  end

  def test_has_security_key_returns_false_for_blank_key_name_and_sends_no_nphaskey
    RpmsRpc.mock!

    refute RpmsRpc::Authentication.has_security_key?(SYNTHETIC_DUZ, "  ")
    assert_empty nphaskey_calls
  end

  class RefusingNphaskeyMock < RpmsRpc::MockClient
    def call_rpc(rpc_name, *params)
      raise RpmsRpc::Client::RpcError, "Access denied for remote procedure." if rpc_name == NPHASKEY_RPC

      super
    end
  end

  def test_has_security_key_propagates_client_rpc_error_instead_of_returning_false
    mock = RefusingNphaskeyMock.new
    RpmsRpc.configure { |cfg| cfg.client = mock }

    assert_raises(RpmsRpc::Client::RpcError) do
      RpmsRpc::Authentication.has_security_key?(SYNTHETIC_DUZ, SYN_KEY)
    end
  end

  def test_has_security_key_sends_exactly_one_orwu_nphaskey_with_duz_and_key_params
    RpmsRpc.mock! do |m|
      m.seed(:person_has_key, [ SYNTHETIC_DUZ, SYN_KEY ], true)
    end

    RpmsRpc::Authentication.has_security_key?(SYNTHETIC_DUZ, SYN_KEY)

    calls = nphaskey_calls
    assert_equal 1, calls.size
    assert_equal [ SYNTHETIC_DUZ, SYN_KEY ], calls.first[:params]
  end

  def test_has_security_key_does_not_bind_or_change_caller_context
    mock = RpmsRpc::MockClient.new
    mock.create_context(CALLER_CONTEXT)
    mock.seed(:person_has_key, [ SYNTHETIC_DUZ, SYN_KEY ], true)
    binds_before = mock.context_binds.dup
    RpmsRpc.configure { |cfg| cfg.client = mock }

    RpmsRpc::Authentication.has_security_key?(SYNTHETIC_DUZ, SYN_KEY)

    assert_equal CALLER_CONTEXT, mock.current_context
    assert_equal binds_before, mock.context_binds
    refute_includes mock.received_calls.map { |c| c[:rpc] }, "XWB CREATE CONTEXT"
  end

  def test_has_security_key_is_true_for_seeded_scalar_line_one
    RpmsRpc.mock! do |m|
      m.seed(:person_has_key, [ SYNTHETIC_DUZ, SYN_KEY ], true)
    end

    assert RpmsRpc::Authentication.has_security_key?(SYNTHETIC_DUZ, SYN_KEY)
  end

  def test_has_security_key_is_false_for_seeded_scalar_line_zero
    RpmsRpc.mock! do |m|
      m.seed(:person_has_key, [ SYNTHETIC_DUZ, SYN_KEY ], false)
    end

    refute RpmsRpc::Authentication.has_security_key?(SYNTHETIC_DUZ, SYN_KEY)
  end

  # --- contract 5: agree with held_keys on every reply shape ------------------

  NPHASKEY_REPLY_SHAPES = [
    [ "single line one", [ "1" ] ],
    [ "single line zero", [ "0" ] ],
    [ "line two", [ "2" ] ],
    [ "line yes", [ "yes" ] ],
    [ "line true", [ "true" ] ],
    [ "leading space one", [ " 1" ] ],
    [ "trailing space one", [ "1 " ] ],
    [ "empty line", [ "" ] ],
    [ "empty line list", [] ],
    [ "two lines one one", %w[1 1] ],
    [ "two lines one zero", %w[1 0] ],
    [ "two lines zero one", %w[0 1] ],
    [ "altered tab one", [ "\t1" ] ]
  ].freeze

  def assert_has_security_key_agrees_with_held_keys(label)
    held = RpmsRpc::Authentication.held_keys([ SYN_KEY ])
    has = RpmsRpc::Authentication.has_security_key?(SYNTHETIC_DUZ, SYN_KEY)
    expected = !held.nil? && held.include?(SYN_KEY)

    assert_equal expected, has,
                 "shape #{label.inspect}: held_keys=#{held.inspect} must match has_security_key?"
  end

  def test_has_security_key_agrees_with_held_keys_on_every_pinned_nphaskey_reply_shape
    NPHASKEY_REPLY_SHAPES.each do |label, lines|
      with_signed_on_nphaskey_raw_lines(lines)
      assert_has_security_key_agrees_with_held_keys(label)
    end

    mock = AlteredOneLineReplyMock.new
    mock.set_authenticated(SYNTHETIC_DUZ)
    RpmsRpc.configure { |cfg| cfg.client = mock }
    assert_has_security_key_agrees_with_held_keys("altered reply marked line one")
  end
end
