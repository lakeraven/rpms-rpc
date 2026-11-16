# frozen_string_literal: true

require_relative "../shape"
require_relative "../mappings"

module RpmsRpc
  # The chief complaint on a visit, through the RPCs VueCentric's Triage tab
  # files it with (IHSBGOCHIEFCOMPLAINT; BGOCC, BGO COMPONENTS patch 25 on
  # the bcer-9.0 build). Recorded in V NARRATIVE TEXT (#9000010.34) with the
  # narrative type CHIEF COMPLAINT, the signed-on user as its author.
  module ChiefComplaint
    extend self
    extend Shape::Declarable

    # One line of text, as the Triage tab sends it: TOWP^BGOUTL keeps a line
    # of up to 240 characters whole (BGOUTL.m:388-401). A caret would end the
    # piece, and a control character is not text.
    MAX_TEXT = 240
    TEXT_FORMAT = /\A[\x20-\x7E]+\z/

    # The chief complaints recorded on a visit, newest last.
    #
    #   for_visit(visit_ien) => [{ ien:, author_duz:, author_name:, text: }, ...]
    #
    # GET^BGOCC answers, per V NARRATIVE TEXT of type CHIEF COMPLAINT, a
    # header IEN^DUZ~NAME^LINE COUNT followed by its lines, and last the
    # VISIT's own CHIEF COMPLAINT field (#9000010, 14) as IEN 0 when that is
    # set. The text comes formatted for display: a first line that is not
    # numbered ("1.) ...") reads "1.) Patient complains of ;" and the line as
    # filed, and the VISIT field reads "Emergency Room Triage: " and the
    # field. An error is one -n^text line, which raises: a failed read is not
    # "none recorded".
    def for_visit(visit_ien)
      return [] if invalid_id?(visit_ien)

      lines = read_lines(visit_ien.to_s)
      raise Client::RpcError, "BGOCC GET refused: #{lines.first}" if DataMapper.error_row?(lines.first.to_s)

      entries(lines)
    end
    shape :for_visit, resource: "chief-complaints", verb: "GET", path: "/visits/{visit_ien}/chief-complaints"

    # File a chief complaint on a visit, as the signed-on user.
    #
    #   record(visit_ien, text) => { success:, ien:, raw:, error: }
    #
    # SET^BGOCC takes VISIT IEN ^ V NARRATIVE IEN ^ TEXT; an empty second
    # piece files a new entry. It refuses a visit that is missing or locked,
    # or whose service category is not A, I, T or M (CHKVISIT^BGOUTL), as
    # -n^text. Text the wire cannot carry is refused before anything is sent.
    def record(visit_ien, text)
      return refusal(:invalid_visit) if invalid_id?(visit_ien)
      return refusal(:invalid_text) unless valid_text?(text)

      raw = DataMapper.chief_complaint_set.fetch_scalar("#{visit_ien}^^#{text}")
      ien = raw.to_s[/\A[1-9]\d*\z/]&.to_i
      return { success: true, ien: ien, raw: raw, error: nil } if ien

      refusal(:refused, raw: raw)
    end
    shape :record, resource: "chief-complaints", verb: "POST", path: "/chief-complaints"

    def valid_text?(text)
      text.is_a?(String) && text.length <= MAX_TEXT && text.match?(TEXT_FORMAT) &&
        !text.include?("^") && !text.strip.empty?
    end

    private

    def read_lines(visit_ien)
      mapping = DataMapper.chief_complaints
      client = RpmsRpc.client
      reply = mapping.in_context(client) do
        client.respond_to?(:call_rpc_lines) ? client.call_rpc_lines(mapping.rpc_name, visit_ien) : client.call_rpc(mapping.rpc_name, visit_ien)
      end
      reply = reply.split(/\r\n|\r|\n/) if reply.is_a?(String)
      Array(reply).map { |line| DataMapper.strip_recordset_separators(line.to_s) }.reject(&:empty?)
    end

    def entries(lines)
      found = []
      until lines.empty?
        ien, author, count = lines.shift.split("^", 3)
        duz, name = author.to_s.split("~", 2)
        text = lines.shift(count.to_i).join("\n")
        found << { ien: ien.to_i, author_duz: duz.to_s[/\A\d+\z/]&.to_i, author_name: name, text: text }
      end
      found
    end

    def refusal(error, raw: nil)
      { success: false, ien: nil, raw: raw, error: error }
    end

    def invalid_id?(value)
      value.nil? || !value.to_s.match?(/\A[1-9]\d*\z/)
    end
  end
end
