# frozen_string_literal: true

require_relative "../shape"
require_relative "../context_scope"

module RpmsRpc
  # Insurance eligibility (Medicare and Medicaid) through the IHS AG package
  # and the BQI read. This is payer coverage, not VFC immunization eligibility:
  # RpmsRpc::Eligibility stays on BGOVIMM GETVFC / BGOVIMM2 GETELIG.
  #
  # ## Context — this module binds it, callers do not
  #
  # AGG UPDATE MEDICARE and AGG UPDATE MEDICAID are registered under AGGRPC
  # only (the same option as RpmsRpc::Agg::CONTEXT). BQI PATIENT INSURANCE is
  # registered under BQIRPC only. Every call scopes itself with
  # ContextScope#with_context and restores the caller's option afterward. A
  # client that cannot scope contexts runs as-is.
  #
  # ## Session hygiene
  #
  # AG routines leak un-NEWed locals into a long-lived broker job (the same
  # caveat as RpmsRpc::Agg). Prefer a short session for a coverage workflow;
  # do not stack many AGG writes on one long-lived session.
  #
  # ## Wire
  #
  # BQI PATIENT INSURANCE (GET^BQIPTINS) takes the DFN only. The reply is a
  # global array: a typed header, then INSURANCE_COVERAGE^EFFECTIVE_DATE rows.
  # An empty or header-only reply is no rows, never a fabricated entry.
  #
  # AGG UPDATE MEDICARE (UPD^AGGUPMCR) takes DFN, PROC, DEF, MIEN, PARMS.
  # AGG UPDATE MEDICAID (UPD^AGGUPMCD) takes DFN, PROC, DEF, RIEN, MIEN, PARMS.
  # PARMS is $C(28)-delimited NAME=VALUE. PROC is A, E, or D. The data row is
  # RESULT^ERROR^RIEN^MIEN: RESULT 1 is success; -1 carries the error text.
  # An empty reply is not success.
  #
  # A caret or an ASCII control in a value that would be placed on the wire
  # is refused before any RPC. An invalid DFN makes no call.
  module Coverage
    extend self
    extend Shape::Declarable

    EMPTY = { entries: [].freeze }.freeze

    # ^AGG(9009068.3,"B",…) window names.
    MEDICARE_WINDOW = "Medicare" # IEN 11, file 9000003
    MEDICARE_ELIGIBILITY_WINDOW = "Medicare Eligibility" # IEN 13, file 9000003.11
    MEDICAID_WINDOW = "Medicaid" # IEN 10, file 9000004
    MEDICAID_ELIGIBILITY_WINDOW = "Medicaid Eligibility" # IEN 12, file 9000004.11

    # Same option RpmsRpc::Agg binds. Named here so a coverage call does not
    # depend on the registration module being the caller.
    AGG_CONTEXT = "AGGRPC"
    BQI_CONTEXT = "BQIRPC"

    MEDICARE_RPC = "AGG UPDATE MEDICARE" # UPD^AGGUPMCR
    MEDICAID_RPC = "AGG UPDATE MEDICAID" # UPD^AGGUPMCD
    BQI_RPC = "BQI PATIENT INSURANCE" # GET^BQIPTINS

    PARM_DELIM = "\x1c" # $C(28)
    RECORD_SEP = "\x1e" # $C(30)
    ARRAY_END = "\x1f" # $C(31)
    ACK = "\x00"
    PROCS = %w[A E D].freeze
    CONTROL = /[\x00-\x1f\x7f]/
    CANONICAL_DFN = /\A[1-9]\d*\z/

    # Active insurance rows for a patient: { entries: [{ coverage:, effective_on: }] }.
    # EMPTY when the DFN is not a positive integer or the broker returns no
    # data row. Absence is not turned into a row.
    def for_patient(dfn, client: RpmsRpc.client)
      id = canonical_dfn(dfn)
      return EMPTY unless id

      raw = scoped(client, BQI_CONTEXT) { call_array(client, BQI_RPC, id) }
      rows = insurance_rows(raw)
      rows.empty? ? EMPTY : { entries: rows }
    end
    shape :for_patient, resource: "coverages", verb: "GET", path: "/patients/{dfn}/coverages"

    # UPD^AGGUPMCR. Returns { success:, error:, message:, rien:, mien: },
    # or nil when the broker returns nothing that can be read as a reply.
    # rien is the patient IEN (integer when the piece is digits). mien is
    # the eligibility multiple IEN as text.
    def medicare_update(dfn, proc:, definition:, mien: "", params: {}, client: RpmsRpc.client)
      procedure = require_proc!(proc)
      encoded = encode_params(params || {})
      window = wire!(definition)
      multiple = wire!(mien)
      id = canonical_dfn(dfn)
      return nil unless id

      scoped(client, AGG_CONTEXT) do
        finish_medicare(call_array(client, MEDICARE_RPC, id, procedure, window, multiple, encoded))
      end
    end
    shape :medicare_update, resource: "coverages", verb: "POST",
          path: "/patients/{dfn}/coverages/medicare-update"

    # UPD^AGGUPMCD. record_ien is the #9000004 IEN (not the DFN); on PROC A
    # with record_ien blank the routine lays a new record in with FILE^DICN.
    # Returns { success:, error:, message:, record_ien:, multiple_ien: },
    # or nil on an empty reply.
    def medicaid_update(dfn, proc:, definition:, record_ien: "", multiple_ien: "", params: {}, client: RpmsRpc.client)
      procedure = require_proc!(proc)
      encoded = encode_params(params || {})
      window = wire!(definition)
      record = wire!(record_ien)
      multiple = wire!(multiple_ien)
      id = canonical_dfn(dfn)
      return nil unless id

      scoped(client, AGG_CONTEXT) do
        finish_medicaid(call_array(client, MEDICAID_RPC, id, procedure, window, record, multiple, encoded))
      end
    end
    shape :medicaid_update, resource: "coverages", verb: "POST",
          path: "/patients/{dfn}/coverages/medicaid-update"

    # File the Medicare header (name, number, suffix, release-of-information
    # date), then a Medicare Eligibility row dated effective_on. The returned
    # rien and mien come from the eligibility reply (pieces 3 and 4).
    def add_medicare(dfn, roi_on:, name:, number:, suffix: nil, effective_on:, client: RpmsRpc.client)
      header_params = {
        "AGGMCROI" => roi_on,
        "AGGMCNME" => name,
        "AGGMCNUM" => number,
        "AGGMCSUF" => suffix
      }
      eligibility_params = { "AGGMCESD" => effective_on }
      encode_params(header_params)
      encode_params(eligibility_params)
      return nil unless canonical_dfn(dfn)

      filed = medicare_update(dfn, proc: "A", definition: MEDICARE_WINDOW, params: header_params, client: client)
      return filed unless filed && filed[:success]

      medicare_update(dfn, proc: "A", definition: MEDICARE_ELIGIBILITY_WINDOW,
                      params: eligibility_params, client: client)
    end
    shape :add_medicare, resource: "coverages", verb: "POST", path: "/patients/{dfn}/coverages/medicare"

    # Delete the eligibility multiple, then the Medicare header. The header
    # delete is the one that removes ^AUPNMCR(DFN) (AGGUPMCR.m:37-41).
    def delete_medicare(dfn, eligibility_mien:, client: RpmsRpc.client)
      wire!(eligibility_mien)
      return nil unless canonical_dfn(dfn)

      removed = medicare_update(dfn, proc: "D", definition: MEDICARE_ELIGIBILITY_WINDOW,
                                mien: eligibility_mien, client: client)
      return removed unless removed && removed[:success]

      medicare_update(dfn, proc: "D", definition: MEDICARE_WINDOW, mien: "", client: client)
    end
    shape :delete_medicare, resource: "coverages", verb: "DELETE", path: "/patients/{dfn}/coverages/medicare"

    # Lay in a Medicaid record (PROC A, RIEN blank), then an eligibility row
    # on that record with the effective date and coverage type. record_ien
    # and multiple_ien are the eligibility reply's pieces 3 and 4.
    def add_medicaid(dfn, effective_on:, coverage: "FULL", client: RpmsRpc.client)
      eligibility_params = { "AGGMDESD" => effective_on, "AGGMDECV" => coverage }
      encode_params(eligibility_params)
      return nil unless canonical_dfn(dfn)

      header = medicaid_update(dfn, proc: "A", definition: MEDICAID_WINDOW, client: client)
      return header unless header && header[:success]

      medicaid_update(dfn, proc: "A", definition: MEDICAID_ELIGIBILITY_WINDOW,
                      record_ien: header[:record_ien], params: eligibility_params, client: client)
    end
    shape :add_medicaid, resource: "coverages", verb: "POST", path: "/patients/{dfn}/coverages/medicaid"

    # Delete the eligibility row, then the header record. When the row was
    # the last one, UPD^AGGUPMCD already kills the #9000004 record
    # (AGGUPMCD.m:41-45), and the header call answers that the entry does
    # not exist. That follow-up is still success: the record is gone.
    def delete_medicaid(dfn, record_ien:, eligibility_mien:, client: RpmsRpc.client)
      wire!(record_ien)
      wire!(eligibility_mien)
      return nil unless canonical_dfn(dfn)

      removed = medicaid_update(dfn, proc: "D", definition: MEDICAID_ELIGIBILITY_WINDOW,
                                record_ien: record_ien, multiple_ien: eligibility_mien, client: client)
      return removed unless removed && removed[:success]

      header = medicaid_update(dfn, proc: "D", definition: MEDICAID_WINDOW,
                               record_ien: record_ien, multiple_ien: "", client: client)
      return header if header.nil? || header[:success]
      return removed if header[:message].to_s.match?(/does not exist/i)

      header
    end
    shape :delete_medicaid, resource: "coverages", verb: "DELETE",
          path: "/patients/{dfn}/coverages/records/{record_ien}/medicaid"

    # $C(28)-delimited NAME=VALUE, the PARMS string both AGG updates take.
    # nil values are dropped. A delimiter in a name or a value, a caret in
    # either, or an ASCII control is refused — nothing is sent.
    def encode_params(params)
      pairs = (params || {}).reject { |_, value| value.nil? }.map { |name, value| [ wire!(name), wire!(value) ] }
      pairs.map { |name, value| "#{name}=#{value}" }.join(PARM_DELIM)
    end

    private

    def scoped(client, option, &block)
      ContextScope.scoped(client, option, &block)
    end

    def require_proc!(proc)
      text = proc.to_s
      raise ArgumentError, "proc must be A, E, or D" unless PROCS.include?(text)

      text
    end

    # Positive integer DFN as it will appear on the wire, or nil.
    def canonical_dfn(dfn)
      text = dfn.is_a?(Integer) ? dfn.to_s : dfn
      return unless text.is_a?(String) && text.match?(CANONICAL_DFN)

      text
    end

    def wire!(value)
      text = value.to_s
      if text.include?(PARM_DELIM)
        raise ArgumentError, "coverage parameters must not contain the parameter delimiter"
      end
      raise ArgumentError, "coverage parameters must not contain a caret" if text.include?("^")
      raise ArgumentError, "coverage parameters must not contain a control character" if text.match?(CONTROL)

      text
    end

    def call_array(client, rpc, *params)
      if client.respond_to?(:call_rpc_global_array)
        client.call_rpc_global_array(rpc, *params)
      else
        client.call_rpc(rpc, *params)
      end
    end

    # nil when the reply is empty. Otherwise the non-blank $C(30) rows, header first.
    def framed_rows(raw)
      return nil if raw.nil?

      body = raw.to_s
      body = body.split(ACK, 2).last.to_s if body.include?(ACK)
      body = body.split(ARRAY_END, 2).first.to_s
      return nil if body.strip.empty?

      body.split(RECORD_SEP).reject { |row| row.strip.empty? }
    end

    def pieces(row)
      row.split("^", -1).map { |piece| piece.to_s.strip }
    end

    def insurance_rows(raw)
      rows = framed_rows(raw)
      return [] if rows.nil? || rows.empty?

      rows.drop(1).filter_map do |row|
        coverage, effective = pieces(row)
        next if coverage.to_s.empty? && effective.to_s.empty?

        { coverage: coverage.to_s, effective_on: effective.to_s }
      end
    end

    def result_pieces(raw)
      rows = framed_rows(raw)
      return nil if rows.nil? || rows.empty?
      return :header_only if rows.size == 1

      pieces(rows[1])
    end

    def integer_piece(value)
      text = value.to_s
      return nil if text.empty?

      text.match?(CANONICAL_DFN) || text == "0" ? text.to_i : text
    end

    def finish_medicare(raw)
      row = result_pieces(raw)
      return nil if row.nil?
      if row == :header_only
        return { success: false, error: :coverage_empty_reply,
                 message: "coverage reply carried no data record", rien: nil, mien: nil }
      end

      result, message, rien, mien = row
      body = { message: message.to_s, rien: integer_piece(rien), mien: mien.to_s }
      if result == "1"
        { success: true, error: nil, **body }
      else
        { success: false, error: :coverage_rejected, **body }
      end
    end

    def finish_medicaid(raw)
      row = result_pieces(raw)
      return nil if row.nil?
      if row == :header_only
        return { success: false, error: :coverage_empty_reply,
                 message: "coverage reply carried no data record", record_ien: nil, multiple_ien: nil }
      end

      result, message, record_ien, multiple_ien = row
      body = { message: message.to_s, record_ien: record_ien.to_s, multiple_ien: multiple_ien.to_s }
      if result == "1"
        { success: true, error: nil, **body }
      else
        { success: false, error: :coverage_rejected, **body }
      end
    end
  end
end
