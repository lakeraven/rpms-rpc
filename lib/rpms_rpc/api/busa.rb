# frozen_string_literal: true

require_relative "../client"
require_relative "../context_scope"
require_relative "../shape"
require_relative "agg"

module RpmsRpc
  # BUSA LOG SECURITY AUDIT ENTRY (RPC^BUSARPC). Option: BUSARPC, the only
  # option the pinned build registers this RPC under. The write is an audit
  # record: a reply that is not RESULT 1 is not success.
  module Busa
    extend self
    extend Shape::Declarable

    LOG_RPC = "BUSA LOG SECURITY AUDIT ENTRY"
    CONTEXT = "BUSARPC"
    PIPE = "|"

    # RPC^BUSARPC. Option: BUSARPC. One parameter, CAT|ACTION|CALL|DESC|DETAIL
    # (BUSARPC.m:363-367). A piece that itself contains "|" is refused
    # before the call: the routine would split it into the next piece.
    # Returns { success:, message: } or nil when RPMS did not answer.
    def log_security_audit(category:, action:, call:, description:, detail:)
      pieces = [ category, action, call, description, detail ].map(&:to_s)
      if pieces.any? { |piece| piece.include?(PIPE) }
        raise ArgumentError, "BUSA audit pieces must not contain '|'"
      end

      raw = in_context { call_array(RpmsRpc.client, LOG_RPC, pieces.join(PIPE)) }
      parse_log_reply(raw)
    end
    shape :log_security_audit, resource: "busa", verb: "POST", path: "/busa/log-security-audit"

    # Header I00001RESULT^T00250ERROR_MESSAGE (BUSARPC.m:354). Success is
    # RESULT "1" only. "0^DUZ is not defined" (BUSARPC.m:359) is a failure
    # whose message is the ERROR_MESSAGE piece.
    def parse_log_reply(raw)
      parsed = Agg.parse_reply(raw)
      return nil if parsed.nil?

      record = parsed[:records].first
      return { success: false, message: "#{LOG_RPC} gave no data record" } if record.nil?

      { success: record[:result].to_s == "1", message: record[:error_message].to_s }
    end

    private

    def in_context(&block)
      ContextScope.scoped(RpmsRpc.client, CONTEXT, &block)
    end

    def call_array(client, rpc_name, *params)
      if client.respond_to?(:call_rpc_global_array)
        client.call_rpc_global_array(rpc_name, *params)
      else
        client.call_rpc(rpc_name, *params)
      end
    end
  end
end
