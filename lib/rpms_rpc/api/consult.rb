# frozen_string_literal: true

require_relative "../shape"
require_relative "../mappings"
require_relative "../fileman_date_parser"

module RpmsRpc
  # A patient's consult and procedure requests (REQUEST/CONSULTATION, #123),
  # read the way the Consults tab reads them.
  # Underlying RPCs: ORQQCN LIST (LIST^ORQQCN), ORQQCN GET CONSULT
  # (GETCSLT^ORQQCN1) and ORQQCN CANEDIT (CANEDIT^ORQQCN1).
  module Consult
    extend self
    extend Shape::Declarable

    CONSULT_ROW = /\A[1-9]\d*\^/
    # END^GMRCSLM1 writes this line when the patient has no request in the
    # range asked (GMRCSLM1.m:93), then a "Between Dates:" and a "With
    # Status:" line when those were asked (:94-95).
    NONE_ON_FILE = "< PATIENT DOES NOT HAVE ANY CONSULTS/REQUESTS"
    TYPE_BY_CODE = { "C" => :consult, "P" => :procedure, "M" => :clinical_procedure,
                     "I" => :interfacility_consult, "R" => :interfacility_procedure }.freeze

    # The patient's requests, newest first as GMRC files them.
    #
    #   for_patient(dfn, start_date: nil, end_date: nil, service_ien: nil, status_iens: nil)
    #   => [{ ien:, requested_at:, status:, service:, kind:, significant_findings:,
    #         title:, order_ien:, type: }, ...]
    #
    # From OER^GMRCSLM1 with GMRCOER=2 (GMRCSLM1.m:76-90): status is the
    # ORDER STATUS (#100.01) abbreviation, service the TO SERVICE (#123.5)
    # name (a grouper service in <angle brackets>), kind "Consult" or the
    # procedure name, title the order text the routine builds, type from
    # piece 9 (:consult, :procedure, :clinical_procedure, and the two
    # interfacility kinds). start_date/end_date narrow the request date
    # (both or neither); service_ien is a #123.5 IEN (blank is ALL SERVICES,
    # GMRCSLM1.m:115); status_iens a list of #100.01 IENs. [] when the
    # patient has none; a -N^text reply, or a line off this layout,
    # raises Client::RpcError.
    def for_patient(dfn, start_date: nil, end_date: nil, service_ien: nil, status_iens: nil)
      return [] unless positive_id?(dfn)

      statuses = Array(status_iens).map(&:to_s)
      return [] unless statuses.all? { |s| positive_id?(s) } && (service_ien.nil? || positive_id?(service_ien))

      lines = DataMapper.consult_list.lines!(dfn.to_s, fileman(start_date), fileman(end_date),
                                             service_ien.to_s, statuses.join(","))
      rows = lines.select { |line| line.match?(CONSULT_ROW) }
      return rows.map { |line| list_row(line.split("^", -1)) } unless rows.empty?
      return [] if lines.empty? || lines.first.lstrip.start_with?(NONE_ON_FILE)

      raise Client::RpcError, RpmsRpc.sanitize_error("ORQQCN LIST answered #{lines.first.inspect}, not a consult row")
    end
    shape :for_patient, resource: "consults", verb: "GET", path: "/patients/{dfn}/consults"

    # One request: its #123 zero node by field, and the results linked to
    # it (TIU notes, and medicine results when the build carries them).
    #
    #   find(consult_ien) => { ien:, entered_at:, patient_dfn:, order_ien:, patient_location_ien:,
    #                          to_service_ien:, from_location_ien:, requested_at:, procedure:,
    #                          urgency_ien:, place_ien:, attention_duz:, status_ien:,
    #                          last_action_ien:, sending_provider_duz:, sending_provider:,
    #                          request_type:, service_rendered:, significant_findings:, results: [] }
    #
    # GETCSLT^ORQQCN1 (ORQQCN1.m:63-90): line 0 is the zero node (DOCLIST^
    # GMRCGUIB, piece 20 cleared) with piece 14 rewritten "DUZ;NAME"; each
    # following line is a linked result, a TIU note as IEN^RESOLVE^TIUSRVLO
    # text with piece 14 "1", a medicine result as sent with piece 14 "2".
    # Values are internal: pointers stay IENs, procedure the variable
    # pointer as filed. nil for a consult not on file (the routine answers
    # "-1^Invalid consult", ORQQCN1.m:67).
    def find(consult_ien)
      return nil unless positive_id?(consult_ien)

      mapping = DataMapper.consult_record
      client = RpmsRpc.client
      reply = mapping.in_context(client) { client.call_rpc(mapping.rpc_name, consult_ien.to_s, "") }
      lines = Array(reply.is_a?(String) ? reply.split(/\r\n|\r|\n/) : reply).map(&:to_s).reject(&:empty?)
      return nil if lines.empty? || lines.first.start_with?("-1^Invalid consult")
      raise Client::RpcError, RpmsRpc.sanitize_error("ORQQCN GET CONSULT refused: #{lines.first}") if DataMapper.error_row?(lines.first)

      record(consult_ien.to_i, lines.first.split("^", -1), lines.drop(1))
    end
    shape :find, resource: "consults", verb: "GET", path: "/consults/{consult_ien}"

    # Whether a cancelled request may be edited and resubmitted:
    # $$EDRESOK^GMRCEDT2 (CANEDIT^ORQQCN1, ORQQCN1.m:117). "1" answers
    # { resubmittable: true, reason: nil }; "0^text" (an interfacility
    # request owned by the other site, a service no longer orderable, a
    # consult not on file) answers false with the routine's reason.
    # Anything else raises Client::RpcError.
    def resubmittable(consult_ien)
      return nil unless positive_id?(consult_ien)

      raw = Array(DataMapper.consult_resubmittable.fetch_scalar(consult_ien.to_s)).first.to_s
      flag, reason = raw.split("^", 2)
      raise Client::RpcError, "ORQQCN CANEDIT answered #{raw.inspect}, neither 1 nor 0^reason" unless %w[0 1].include?(flag)

      { resubmittable: flag == "1", reason: reason.to_s.empty? ? nil : reason }
    end
    shape :resubmittable, resource: "consults", verb: "GET", path: "/consults/{consult_ien}/resubmittable"

    private

    def list_row(pieces)
      ien, requested, status, service, kind, findings, title, order, type = pieces
      { ien: ien.to_i, requested_at: FilemanDateParser.parse_datetime_or_date(requested.to_s),
        status: presence(status), service: presence(service), kind: presence(kind),
        significant_findings: findings == "*", title: presence(title),
        order_ien: positive_id?(order) ? order.to_i : nil, type: TYPE_BY_CODE[type.to_s] }
    end

    def record(ien, zero, result_lines)
      sender_duz, sender_name = zero[13].to_s.split(";", 2)
      { ien: ien, entered_at: FilemanDateParser.parse_datetime_or_date(zero[0].to_s),
        patient_dfn: id(zero[1]), order_ien: id(zero[2]), patient_location_ien: id(zero[3]),
        to_service_ien: id(zero[4]), from_location_ien: id(zero[5]),
        requested_at: FilemanDateParser.parse_datetime_or_date(zero[6].to_s), procedure: presence(zero[7]),
        urgency_ien: id(zero[8]), place_ien: id(zero[9]), attention_duz: id(zero[10]),
        status_ien: id(zero[11]), last_action_ien: id(zero[12]),
        sending_provider_duz: id(sender_duz), sending_provider: presence(sender_name),
        request_type: presence(zero[16]), service_rendered: presence(zero[17]),
        significant_findings: presence(zero[18]), results: result_lines.map { |line| result(line.split("^", -1)) } }
    end

    def result(pieces)
      kind = pieces[13] == "2" ? :medicine : :note
      return { kind: kind, ien: id(pieces[0]), title: presence(pieces[1]) } if kind == :note

      { kind: kind, reference: presence(pieces[0]), title: presence(pieces[1]) }
    end

    def id(value)
      positive_id?(value) ? value.to_i : nil
    end

    def fileman(value)
      case value
      when nil then ""
      when Time then FilemanDateParser.format_datetime(value)
      when Date then FilemanDateParser.format_date(value)
      else value.to_s
      end
    end

    def positive_id?(value)
      value.to_s.match?(/\A[1-9]\d*\z/)
    end

    def presence(value)
      value.to_s.empty? ? nil : value
    end
  end
end
