# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/bmx_client"

# #472 / #474, panel round 2. fixed_width guards five fields; only the ones
# inside build_bmx_message are limited by the broker's 512-byte request cut.
# The connect and session packet length fields are not, so a message that says
# "the broker cuts a request at 512 bytes" for them names the wrong cause.
class BmxFixedWidthMessageTest < Minitest::Test
  Client = RpmsRpc::BmxClient

  class NullSocket
    attr_reader :writes

    def initialize = @writes = []
    def write(str) = (@writes << str.b) && str.bytesize
    def flush; end
    def close; end
    def closed? = false
    def setsockopt(*); end
  end

  def client
    c = Client.new
    c.instance_variable_set(:@socket, NullSocket.new)
    c
  end

  def test_a_direct_overflow_names_the_field_and_not_the_request_cap
    error = assert_raises(Client::RequestTooLongError) { Client.new.send(:fixed_width, 100_000, 5, "length") }
    assert_match(/100000/, error.message)
    assert_match(/5-digit/, error.message)
    refute_match(/512/, error.message, "the 512-byte cut is not why an arbitrary field overflows")
  end

  def test_an_overflow_inside_a_request_names_the_request_cap
    error = assert_raises(Client::RequestTooLongError) do
      Client.new.send(:fixed_width, 1000, 3, "param length", request: true)
    end
    assert_match(/param length/, error.message)
    assert_match(/512/, error.message)
  end

  def test_the_connect_packet_message_names_the_packet_not_the_request_cap
    c = client
    error = assert_raises(Client::RequestTooLongError) { c.send(:send_bmx_packet, "x" * 100_000) }
    assert_match(/packet/, error.message)
    refute_match(/512/, error.message)
    assert_empty c.instance_variable_get(:@socket).writes
  end

  def test_the_session_packet_message_names_the_packet_not_the_request_cap
    c = client
    error = assert_raises(Client::RequestTooLongError) { c.send(:send_bmx_session_packet, "x" * 100_000) }
    assert_match(/packet/, error.message)
    refute_match(/512/, error.message)
    assert_empty c.instance_variable_get(:@socket).writes
  end

  def test_an_oversized_param_names_the_param_and_the_request_cap
    error = assert_raises(Client::RequestTooLongError) { Client.new.build_bmx_message("ECHO", [ "x" * 999 ]) }
    assert_match(/param/, error.message)
    assert_match(/512/, error.message)
  end
end
