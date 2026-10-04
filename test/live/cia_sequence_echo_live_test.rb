# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/patient"
require "rpms_rpc/api/scheduling"

# CiaClient#read_reply takes a piece as this request's reply only when its
# first byte is the request's sequence echo (#289). That rests on a broker
# fact: CIANBLIS writes the frame's one-byte sequence (1..9, wrapping) ahead
# of EVERY reply (`W SEQ`, CIANBLIS.m:135). These specs prove the fact and
# the correlation against the pinned build. The case no server produces on
# demand (a stale tail arriving in flight with another reply's bytes) stays a
# hand-written client-mechanics test in test/rpms_rpc/cia_client_test.rb.
#
# These specs read only; they file nothing.
class CiaSequenceEchoLiveTest < LiveSpec::Test
  # More exchanges than the sequence has values, so the echo wraps 9 -> 1.
  EXCHANGES = 20

  def test_every_raw_reply_opens_with_the_sequence_echo_of_its_own_frame
    echoes = EXCHANGES.times.map do
      raw = client.call_rpc_raw("ORWPT LIST ALL", "DEMO", "1")
      sent = client.instance_variable_get(:@seq)
      [ sent.to_s, raw.b.byteslice(0, 1) ]
    end

    echoes.each { |sent, got| assert_equal sent, got, "a reply carried another frame's echo" }
    assert_includes echoes.map(&:first), "9"
    assert_operator echoes.map(&:first).count("1"), :>=, 2, "the sequence never wrapped"
  end

  def test_replies_across_a_sequence_wrap_each_answer_their_own_request
    rows = RpmsRpc::Patient.search("DEMO")
    assert_operator rows.size, :>, 1, "need two patients to tell one reply from the next"

    EXCHANGES.times do |i|
      row = rows[i % rows.size]
      found = RpmsRpc::Patient.find(row[:dfn])
      refute_nil found, "ORWPT SELECT found no patient #{row[:dfn]}"
      assert_equal row[:name], found[:name], "exchange #{i + 1} returned another request's reply"
    end
  end

  # The desync of #254 followed a GLOBAL ARRAY reply: a tail of it answered
  # the next request. After a recordset, the next requests answer themselves.
  def test_the_requests_after_a_recordset_answer_themselves
    rows = RpmsRpc::Patient.search("DEMO")
    assert_operator rows.size, :>, 1, "need two patients to tell one reply from the next"

    clinics = client.with_context("BSDXRPC") { RpmsRpc::Scheduling.hospital_locations }
    refute_empty clinics, "BSDX HOSPITAL LOCATION returned no clinic"

    rows.first(3).each do |row|
      assert_equal row[:name], RpmsRpc::Patient.find(row[:dfn])&.dig(:name),
                   "a request after the recordset was answered with another reply"
    end
  end
end
