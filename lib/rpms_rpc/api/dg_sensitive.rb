# frozen_string_literal: true

require_relative "../client"
require_relative "../context_scope"
require_relative "../mappings"
require_relative "../shape"
require_relative "agg"

module RpmsRpc
  # DG SENSITIVE RECORD ACCESS (PTSEC^DGSEC4) and DG SENSITIVE RECORD
  # BULLETIN (NOTICE^DGSEC4). The pinned build registers both under
  # OR CPRS GUI CHART, SCMC PCMM GUI WORKSTATION, PSB GUI CONTEXT - USER,
  # and ORRCMC DASHBOARD. The wrapper scopes OR CPRS GUI CHART.
  # CiaClient#authenticate leaves CIAV VUECENTRIC bound; ContextScope.scoped
  # binds OR CPRS GUI CHART for the call and restores that session.
  #
  # PTSEC's documented #8994 return lists codes -1..4. The routine on the
  # pinned image also returns 5 for restricted access (DGSEC4.m:43-46,
  # PATCH 1008). 5 is preserved as its own code. It is not success and it
  # is not rewritten to -1. Return type 2 (ARRAY): one line per RESULT
  # node, no typed header, no $C(31) sentinel (DGSEC4.m:13-66). The call
  # writes a DG SECURITY LOG entry (DGSEC4.m:65).
  module DgSensitive
    extend self
    extend Shape::Declarable

    ACCESS_RPC = "DG SENSITIVE RECORD ACCESS"
    BULLETIN_RPC = "DG SENSITIVE RECORD BULLETIN"
    CONTEXT = "OR CPRS GUI CHART"

    # PTSEC^DGSEC4 (DGSEC4.m:13-66). Return type 2 (ARRAY): one line per
    # RESULT node, no typed header, no $C(31) sentinel. The first line is
    # RESULT(1), the integer code, including 5. The following lines are
    # RESULT(2+). Option: OR CPRS GUI CHART (this method scopes it).
    # A blank DFN is the routine's own -1 ("Required variable missing.",
    # DGSEC4.m:36-38) and sends nothing. Any other DFN that is not a
    # positive integer is -1 / "DFN must be a positive integer." and sends
    # nothing. The wire value is the canonical digit string. The call
    # writes a DG SECURITY LOG entry (DGSEC4.m:65). Returns
    # { result:, messages: } or nil when RPMS did not answer.
    def check_access(dfn:, generate_message: 0, option: "")
      return missing_dfn if dfn.nil? || dfn.to_s.strip.empty?

      id = Agg.canonical_dfn(dfn)
      return invalid_dfn unless id

      client = RpmsRpc.client
      raw = in_context(client) do
        client.call_rpc(ACCESS_RPC, id, generate_message.to_s, option.to_s)
      end
      parse_access_reply(raw)
    end
    shape :check_access, resource: "sensitive-records", verb: "POST",
          path: "/patients/{dfn}/sensitive-records/check-access"

    # NOTICE^DGSEC4. Option: OR CPRS GUI CHART. A DFN that is not a positive
    # integer, including a blank, raises ArgumentError before the call.
    # Client order is DFN, DGOPT, ACTION (DGSEC4.m:67). ACTION defaults to
    # 3 in the routine; this method sends the value it was given. The wire
    # DFN is the canonical digit string. Success is the single value "1"
    # only. Returns { success: } or nil.
    def record_bulletin(dfn:, action:, option:)
      id = Agg.canonical_dfn(dfn)
      raise ArgumentError, "DFN must be a positive integer" unless id

      client = RpmsRpc.client
      raw = in_context(client) do
        DataMapper.dg_sensitive_bulletin.fetch_scalar(id, option.to_s, action.to_s)
      end
      parse_bulletin_result(raw)
    end
    shape :record_bulletin, resource: "sensitive-records", verb: "POST",
          path: "/patients/{dfn}/sensitive-records/bulletin"

    # PTSEC^DGSEC4 return type 2 (DGSEC4.m:13-66): an Array or Reply of
    # lines, or a String split on line breaks. The first line is RESULT(1);
    # the rest are RESULT(2+). Nil when there is no line, or the first line
    # (stripped) is not an integer. A code that is not an integer is nil,
    # never 0.
    def parse_access_reply(lines)
      rows = lines.is_a?(String) ? lines.split(/\r\n|\r|\n/) : lines
      return nil if rows.nil? || rows.empty?

      code = rows.first.to_s.strip
      return nil unless code.match?(/\A-?\d+\z/)

      { result: Integer(code), messages: rows.drop(1).map(&:to_s).reject(&:empty?) }
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
      { result: -1, messages: [ "Required variable missing." ] }
    end

    def invalid_dfn
      { result: -1, messages: [ "DFN must be a positive integer." ] }
    end

    def in_context(client, &block)
      ContextScope.scoped(client, CONTEXT, &block)
    end
  end
end
