# frozen_string_literal: true

require_relative "../client"
require_relative "../context_scope"
require_relative "../mappings"
require_relative "../shape"

module RpmsRpc
  # BGU MAILMAN MESSAGE (EN^BGUMAIL). Option: CIAV VUECENTRIC, the only
  # option the pinned build registers this RPC under. EN^BGUMAIL sets
  # BGUARRAY(1)=1 and BGUARRAY(2)="OK" (BGUMAIL.m:6) after the send.
  # The body is one parameter; the routine splits it on $C(175) (BGUMAIL.m:11).
  module Bgu
    extend self
    extend Shape::Declarable

    MAIL_RPC = "BGU MAILMAN MESSAGE"
    CONTEXT = "CIAV VUECENTRIC"

    # Option: CIAV VUECENTRIC. Params: subject, body, group.
    # Success is result "1" only. A two-node array ("1", "OK") and a single
    # "1^OK" record are the same answer. Returns { success:, status: } or nil.
    def send_mailman_message(subject:, body:, group:)
      raw = in_context do
        RpmsRpc.client.call_rpc(MAIL_RPC, subject.to_s, body.to_s, group.to_s)
      end
      mailman_result(raw)
    end
    shape :send_mailman_message, resource: "bgu", verb: "POST", path: "/bgu/send-mailman-message"

    private

    def in_context(&block)
      ContextScope.scoped(RpmsRpc.client, CONTEXT, &block)
    end

    def mailman_result(raw)
      return nil if raw.nil? || raw == "" || (raw.is_a?(Array) && raw.empty?)

      lines = Array(raw).flat_map { |line| line.to_s.split(/\r?\n/) }.map(&:strip).reject(&:empty?)
      return nil if lines.empty?

      result, status = if lines.one? && lines.first.include?("^")
        lines.first.split("^", 2)
      else
        [ lines[0], lines[1].to_s ]
      end
      return nil if result.to_s.empty?

      { success: result == "1", status: status.to_s }
    end
  end
end
