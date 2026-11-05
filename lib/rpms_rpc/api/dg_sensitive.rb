# frozen_string_literal: true

require_relative "../client"
require_relative "../context_scope"
require_relative "../mappings"
require_relative "../shape"
require_relative "agg"

module RpmsRpc
  # DG SENSITIVE RECORD ACCESS (PTSEC^DGSEC4) and DG SENSITIVE RECORD
  # BULLETIN (NOTICE^DGSEC4). Option: OR CPRS GUI CHART, one of the four
  # options the pinned build registers these RPCs under. CIAV VUECENTRIC
  # is not one of them; a session already bound there is refused before
  # any call.
  #
  # PTSEC's documented #8994 return lists codes -1..4. The routine on the
  # pinned image also returns 5 for restricted access (DGSEC4.m:43-46,
  # PATCH 1008). 5 is preserved as its own code. It is not success and it
  # is not rewritten to -1.
  module DgSensitive
    extend self
    extend Shape::Declarable

    ACCESS_RPC = "DG SENSITIVE RECORD ACCESS"
    BULLETIN_RPC = "DG SENSITIVE RECORD BULLETIN"

    # Pinned rpc_reach.txt for both RPCs. Hardcoded: the inventory files
    # are not part of the installed gem.
    SERVING = [
      "OR CPRS GUI CHART",
      "SCMC PCMM GUI WORKSTATION",
      "PSB GUI CONTEXT - USER",
      "ORRCMC DASHBOARD"
    ].freeze
    CONTEXT = "OR CPRS GUI CHART"

    # PTSEC^DGSEC4. Option: OR CPRS GUI CHART.
    # A blank DFN is the routine's own -1 ("Required variable missing.",
    # DGSEC4.m:36-38) and sends nothing. Returns { result:, dfn:, messages: }
    # or nil when RPMS did not answer. result is the integer code, including 5.
    def check_access(dfn:, generate_message: 0, option: "")
      return missing_dfn if dfn.nil? || dfn.to_s.strip.empty?

      client = RpmsRpc.client
      ensure_served!(client)
      raw = in_context(client) do
        call_array(client, ACCESS_RPC, dfn.to_s, generate_message.to_s, option.to_s)
      end
      parse_access_reply(raw)
    end
    shape :check_access, resource: "sensitive-records", verb: "GET",
          path: "/patients/{dfn}/sensitive-records/check-access"

    # NOTICE^DGSEC4. Option: OR CPRS GUI CHART. Client order is DFN, DGOPT,
    # ACTION (DGSEC4.m:67). ACTION defaults to 3 in the routine; this method
    # sends the value it was given. Success is the single value "1" only.
    # Returns { success: } or nil.
    def record_bulletin(dfn:, action:, option:)
      client = RpmsRpc.client
      ensure_served!(client)
      raw = in_context(client) do
        DataMapper.dg_sensitive_bulletin.fetch_scalar(dfn.to_s, option.to_s, action.to_s)
      end
      parse_bulletin_result(raw)
    end
    shape :record_bulletin, resource: "sensitive-records", verb: "POST",
          path: "/patients/{dfn}/sensitive-records/bulletin"

    # RESULT^DFN^DGMSG^DGOPT, then one row per RESULT(2+) message.
    # A code that is not an integer is nil, never 0.
    def parse_access_reply(raw)
      parsed = Agg.parse_reply(raw)
      return nil if parsed.nil?

      record = parsed[:records].first
      return nil if record.nil?

      code = record[:result].to_s
      return nil unless code.match?(/\A-?\d+\z/)

      messages = parsed[:rows].drop(1).map { |pieces| pieces.join("^") }.reject(&:empty?)
      { result: code.to_i, dfn: record[:dfn].to_s, messages: messages }
    end

    # NOTICE^DGSEC4's single value: "1" succeeded, "0" did not. Anything
    # else, including a blank, is nil.
    def parse_bulletin_result(raw)
      text = raw.to_s.strip
      return nil unless text.match?(/\A[01]\z/)

      { success: text == "1" }
    end

    private

    def missing_dfn
      { result: -1, dfn: "", messages: [ "Required variable missing." ] }
    end

    def ensure_served!(client)
      return unless client.respond_to?(:current_context)

      current = client.current_context
      return if current.nil? || current.to_s.empty?
      return if SERVING.include?(current)

      raise Client::RpcNotAvailableError, "#{ACCESS_RPC} is not registered under #{current}"
    end

    def in_context(client, &block)
      ContextScope.scoped(client, CONTEXT, &block)
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
