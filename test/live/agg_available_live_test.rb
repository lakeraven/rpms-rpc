# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/agg"

# Agg.available? asks CIANBRPC CANRUN whether this user may run AGG ADD NEW
# PATIENT in the AGGRPC context. CANRUN answers a $DATA value
# (CANRUN^CIANBACT, CIANBACT.m:148): 1, 10 or 11 when the context lists the
# RPC, 0 when it does not. A programmer always reads a literal 1; any other
# user who may run it reads 10 or 11 (#367).
#
# The spec reads the raw answer and holds available? to it, so it is true on
# any build and for any persona; it reads only.
class AggAvailableLiveTest < LiveSpec::Test
  def test_available_agrees_with_the_canrun_answer
    answer = begin
      lines = client.with_context(RpmsRpc::Agg::CONTEXT) do
        client.call_rpc_lines(RpmsRpc::Agg::CANRUN_RPC, RpmsRpc::Agg::ADD_RPC)
      end
      # the client's reply grammar: a \x01 reply raised above; a bare echo is no lines
      Array(lines).first&.strip&.to_i
    rescue RpmsRpc::Client::RpcError
      nil # the broker refused: the user cannot bind the context, or the RPC
    end

    expected = !answer.nil? && answer.positive?
    assert_equal expected, RpmsRpc::Agg.available?(client),
                 "CANRUN answered #{answer.inspect} for #{persona}"
    puts "\n#{persona}: CANRUN #{RpmsRpc::Agg::ADD_RPC} in #{RpmsRpc::Agg::CONTEXT} = #{answer.inspect}, available? #{expected}"
  end
end
