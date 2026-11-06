# frozen_string_literal: true

require_relative "../client"
require_relative "../context_scope"
require_relative "../mappings"
require_relative "../shape"

module RpmsRpc
  # ORWU DT (DT^ORWU) — FileMan date/time. Option: CIAV VUECENTRIC, one of
  # the options the pinned build registers this RPC under (OR CPRS GUI
  # CHART, OR BCMA ORDER COM, ORRCM REPORTING, CIAV VUECENTRIC, XHDXC
  # DESKTOP). DT^ORWU normalizes a midnight fragment, defaults %DT to "TS",
  # and runs ^%DT (ORWU.m:4-7). ^%DT's "-1" is not a datetime.
  module Orwu
    extend self
    extend Shape::Declarable

    DT_RPC = "ORWU DT"
    CONTEXT = "CIAV VUECENTRIC"

    # Option: CIAV VUECENTRIC. Sends X and %DT. flags defaults to "TS",
    # the routine's own default (ORWU.m:7). Returns the FileMan value, or
    # nil when the reply is empty or "-1". A broker RpcError is not rescued.
    def fileman_datetime(expression, flags: "TS", client: RpmsRpc.client)
      text = expression.to_s
      raise ArgumentError, "a FileMan date expression is required" if text.strip.empty?

      raw = in_context(client) { client.call_rpc(DT_RPC, text, flags.to_s) }
      value = raw.is_a?(Array) ? raw.first.to_s : raw.to_s
      value = value.strip
      return nil if value.empty? || value == "-1"

      value
    end
    shape :fileman_datetime, resource: "orwu", verb: "GET", path: "/orwu/fileman-datetime"

    private

    def in_context(client, &block)
      ContextScope.scoped(client, CONTEXT, &block)
    end
  end
end
