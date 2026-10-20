# frozen_string_literal: true

require_relative "../live_helper"
require "rpms_rpc/data_mapper"

# BmxClient's reply parsing, over the wire against a stock BMX session
# (rpms-rpc#200). Each case is one the reference BMX client hit, provoked on
# the broker itself; test/fixtures/bmx/replies.yml holds the same frames,
# captured verbatim, for the hermetic tests in bmx_client_test.rb.
#
#   * a recordset (BMX SQL) splits into its typed header and rows;
#   * a query that matches nothing is the header alone: an empty result;
#   * an M error inside BMX SQL (ERRTRAP^BMXSQL's M_ERROR recordset) raises
#     RpcMError, never rows;
#   * a query error after the $C(31) end marker (ERRTACK^BMXSQL) raises;
#   * the security packet is read by its length: an EOT byte inside it (the
#     refusal quotes the RPC name) does not end the frame early, and the next
#     call reads its own reply.
#
# Needs the BMXRPC context (BMX SQL is registered there). Reads only.
#   BROKER_PROTOCOL=bmx BROKER_PORT=<the image's 9101> rake test:live
class BmxReplyParsingLiveTest < LiveSpec::Test
  broker :bmx

  CONTEXT = "BMXRPC"
  NO_MATCH = "SELECT NAME FROM NEW_PERSON WHERE NAME = 'ZZZNOMATCH'"

  def setup
    super
    client.create_context(CONTEXT)
  rescue RpmsRpc::Client::RpcError => e
    flunk "#{persona} cannot bind #{CONTEXT} on this build (#{e.message}): BMX SQL is registered there"
  end

  def test_a_recordset_splits_into_its_typed_header_and_rows
    rows = client.call_rpc("BMX SQL", "SELECT NAME FROM NEW_PERSON MAXRECORDS:2")

    assert_match(/\AT\d{5}NAME\z/, rows.first, "the first row is the typed column header")
    assert_equal 2, rows.drop(1).length, "MAXRECORDS:2 answers two records: #{rows.inspect}"
    rows.each { |r| refute_match(/[\x1e\x1f]/, r, "a row kept a recordset separator") }
  end

  def test_a_query_that_matches_nothing_is_an_empty_result_not_an_error
    rows = client.call_rpc("BMX SQL", NO_MATCH)

    assert_equal 1, rows.length, "header only: #{rows.inspect}"
    assert_match(/\AT\d{5}NAME\z/, rows.first, "the header row, its $C(30)/$C(31) framing removed")
    assert_empty rows.reject { |r| RpmsRpc::DataMapper.recordset_header_row?(r) }
  end

  def test_an_m_error_inside_bmx_sql_raises_rather_than_returning_rows
    error = assert_raises(RpmsRpc::Client::RpcMError) { client.call_rpc("BMX SQL", "SELECT FROM") }
    assert_match(/BMXSQL/, error.message)
  end

  def test_a_query_error_after_the_end_marker_raises
    error = assert_raises(RpmsRpc::Client::RpcError) { client.call_rpc("BMX SQL", "SELECT NAME FROM NOSUCHFILE") }
    assert_includes error.message, "FIELD NOT FOUND"
  end

  def test_an_eot_in_the_security_text_leaves_the_session_in_step
    assert_raises(RpmsRpc::Client::RpcNotAvailableError) { client.call_rpc("ZZ\x04ZZ") }

    rows = client.call_rpc("BMX SQL", NO_MATCH)
    assert_equal 1, rows.length, "the next call read the tail of the refusal: #{rows.inspect}"
    assert RpmsRpc::DataMapper.recordset_header_row?(rows.first)
  end
end
