# frozen_string_literal: true

require "date"
require_relative "../shape"
require_relative "../context_scope"
require_relative "ddr_fileman"

module RpmsRpc
  # Insurance eligibility (Medicare and Medicaid) through the IHS AG package
  # and the BQI read. This is payer coverage, not VFC immunization eligibility:
  # RpmsRpc::Eligibility stays on BGOVIMM GETVFC / BGOVIMM2 GETELIG.
  #
  # ## Context — this module binds it, callers do not
  #
  # AGG UPDATE MEDICARE and AGG UPDATE MEDICAID are registered under AGGRPC
  # only (the same option as RpmsRpc::Agg::CONTEXT). BQI PATIENT INSURANCE is
  # registered under BQIRPC only. FileMan reads (DDR LISTER, DDR GETS ENTRY
  # DATA) bind CIAV VUECENTRIC, the option sign-on leaves in place. Every call
  # scopes itself with ContextScope#with_context and restores the caller's
  # option afterward. A client that cannot scope contexts runs as-is.
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
  # global array: the typed header T00100INSURANCE_COVERAGE^D00015EFFECTIVE_DATE,
  # then INSURANCE_COVERAGE^EFFECTIVE_DATE rows (BQIPTINS.m:14). for_patient is
  # nil unless that typed header is present and no typed ERROR field is.
  # EMPTY is only that header with no data rows.
  #
  # AGG UPDATE MEDICARE (UPD^AGGUPMCR) takes DFN, PROC, DEF, MIEN, PARMS.
  # AGG UPDATE MEDICAID (UPD^AGGUPMCD) takes DFN, PROC, DEF, RIEN, MIEN, PARMS.
  # PARMS is $C(28)-delimited NAME=VALUE. PROC is A, E, or D. The data row is
  # RESULT^ERROR^RIEN^MIEN: RESULT 1 is success; -1 carries the error text.
  # An empty reply is not success. A MIEN-blank PROC D on Medicare deletes the
  # header (AGGUPMCR.m:37-41); delete_medicare never sends that. It deletes one
  # eligibility row. delete_medicare_record lists #9000003.11 and sends the
  # header delete only when no eligibility rows remain.
  #
  # Names in PARMS must be on the window's ^AGG(9009068.3) "AC" index
  # (UPD refuses any other, AGGUPMCR.m:70-71 and AGGUPMCD.m:68-69). A type D
  # parameter is a calendar date; PARS passes it through $$DATE^AGGUL1
  # (AGGUPMCR.m:286, AGGUPMCD PARS). Dates are refused unless they are a real
  # MM/DD/YYYY. A caret or an ASCII control in a value is refused before any
  # RPC. An invalid DFN makes no call.
  module Coverage
    extend self
    extend Shape::Declarable

    EMPTY = { entries: [].freeze }.freeze

    # ^AGG(9009068.3,"B",…) window names.
    MEDICARE_WINDOW = "Medicare" # IEN 11, file 9000003
    MEDICARE_ELIGIBILITY_WINDOW = "Medicare Eligibility" # IEN 13, file 9000003.11
    MEDICAID_WINDOW = "Medicaid" # IEN 10, file 9000004
    MEDICAID_ELIGIBILITY_WINDOW = "Medicaid Eligibility" # IEN 12, file 9000004.11

    MEDICARE_FILE = "9000003"
    MEDICARE_ELIGIBILITY_FILE = "9000003.11"
    MEDICAID_FILE = "9000004"

    # "AC" index names for each window (UPD's parameter check). Type D names
    # are calendar dates. Read from ^AGG(9009068.3,10/11/12/13,10) on the
    # pinned build; PARS is what files them.
    WINDOW_FIELDS = {
      MEDICARE_WINDOW => %w[
        AGGLSTDT AGGMCABN AGGMCCCF AGGMCCRD AGGMCDOB AGGMCIMP AGGMCINS AGGMCNME
        AGGMCNUM AGGMCPCP AGGMCQMB AGGMCROI AGGMCSTS AGGMCSUF MCELIG SEQNBR
      ].freeze,
      MEDICARE_ELIGIBILITY_WINDOW => %w[
        AGGMCCOV AGGMCEED AGGMCESD AGGMCG AGGMCGN AGGMCIDN AGGMCMN AGGMCPC
        AGGMCPN AGGMRDOB MIEN
      ].freeze,
      MEDICAID_WINDOW => %w[
        AGGLSTDT AGGMDCCF AGGMDCRD AGGMDDOB AGGMDEED AGGMDESD AGGMDGRN AGGMDGRP
        AGGMDINM AGGMDINS AGGMDNME AGGMDNUM AGGMDPCP AGGMDPLN AGGMDRCD AGGMDREL
        AGGMDSTE AGGMDSTS MDELIG RIEN SEQNBR
      ].freeze,
      MEDICAID_ELIGIBILITY_WINDOW => %w[AGGMDECV AGGMDEED AGGMDESD MIEN].freeze
    }.freeze
    DATE_FIELDS = %w[
      AGGLSTDT AGGMCABN AGGMCCRD AGGMCDOB AGGMCIMP AGGMCROI AGGMCEED AGGMCESD
      AGGMRDOB AGGMDCRD AGGMDDOB AGGMDEED AGGMDESD
    ].freeze

    # Same option RpmsRpc::Agg binds. Named here so a coverage call does not
    # depend on the registration module being the caller.
    AGG_CONTEXT = "AGGRPC"
    BQI_CONTEXT = "BQIRPC"
    FILEMAN_CONTEXT = "CIAV VUECENTRIC"

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
    CALENDAR_DATE = /\A\d{2}\/\d{2}\/\d{4}\z/
    # BQI typed-header piece: one type letter, a 5-digit width, then the name.
    TYPED_FIELD = /\A[A-Z]\d{5}(.+)\z/
    INSURANCE_HEADER = %w[INSURANCE_COVERAGE EFFECTIVE_DATE].freeze
    BILLED_ELIGIBILITY = /outstanding claims/i

    # Active insurance rows for a patient: { entries: [{ coverage:, effective_on: }] }.
    # nil when the DFN is not a positive integer, the broker returns nothing,
    # the reply is not BQIPTINS's typed header, or a typed ERROR field is present.
    # EMPTY only when that header arrived with no data rows.
    def for_patient(dfn, client: RpmsRpc.client)
      id = canonical_dfn(dfn)
      return nil unless id

      raw = scoped(client, BQI_CONTEXT) { call_array(client, BQI_RPC, id) }
      rows = framed_rows(raw)
      return nil if rows.nil? || rows.empty?
      return nil unless insurance_header?(rows.first)
      return nil if rows.any? { |row| error_marker?(row) }

      entries = coverage_entries(rows.drop(1))
      entries.empty? ? EMPTY : { entries: entries }
    end
    shape :for_patient, resource: "coverages", verb: "GET", path: "/patients/{dfn}/coverages"

    # UPD^AGGUPMCR. Returns { success:, error:, message:, rien:, mien: },
    # or nil when the broker returns nothing that can be read as a reply.
    # rien is the patient IEN (integer when the piece is digits). mien is
    # the eligibility multiple IEN as text. A non-blank mien must be a
    # positive integer. params are limited to the window's "AC" names.
    def medicare_update(dfn, proc:, definition:, mien: "", params: {}, client: RpmsRpc.client)
      procedure = require_proc!(proc)
      window = wire!(definition)
      multiple = optional_ien!(mien, "mien")
      validate_window_params!(window, params)
      encoded = encode_params(params || {})
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
    # or nil on an empty reply. A non-blank record or multiple IEN must be a
    # positive integer. An outstanding-claims refusal is :billed_eligibility.
    def medicaid_update(dfn, proc:, definition:, record_ien: "", multiple_ien: "", params: {}, client: RpmsRpc.client)
      procedure = require_proc!(proc)
      window = wire!(definition)
      record = optional_ien!(record_ien, "record_ien")
      multiple = optional_ien!(multiple_ien, "multiple_ien")
      validate_window_params!(window, params)
      encoded = encode_params(params || {})
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
    # rien and mien come from the eligibility reply (pieces 3 and 4). A blank
    # or non-positive mien is failure. When this call created the header and
    # the eligibility row does not file, that header is removed.
    def add_medicare(dfn, roi_on:, name:, number:, suffix: nil, effective_on:, client: RpmsRpc.client)
      header_params = {
        "AGGMCROI" => roi_on,
        "AGGMCNME" => name,
        "AGGMCNUM" => number,
        "AGGMCSUF" => suffix
      }
      eligibility_params = { "AGGMCESD" => effective_on }
      validate_window_params!(MEDICARE_WINDOW, header_params)
      validate_window_params!(MEDICARE_ELIGIBILITY_WINDOW, eligibility_params)
      id = canonical_dfn(dfn)
      return nil unless id

      created = medicare_header_absent?(id)
      filed = medicare_update(dfn, proc: "A", definition: MEDICARE_WINDOW, params: header_params, client: client)
      return filed unless filed && filed[:success]

      filed_eligibility = medicare_update(dfn, proc: "A", definition: MEDICARE_ELIGIBILITY_WINDOW,
                                          params: eligibility_params, client: client)
      return filed_eligibility if positive_piece?(filed_eligibility, :mien)

      rolled = created ? rollback_medicare_header(dfn, client) : false
      medicare_eligibility_failure(filed_eligibility, rolled_back: rolled)
    end
    shape :add_medicare, resource: "coverages", verb: "POST", path: "/patients/{dfn}/coverages/medicare"

    # One Medicare Eligibility PROC D, MIEN set. Never a MIEN-blank header
    # delete — that is delete_medicare_record, and only when no eligibility
    # rows remain (AGGUPMCR.m:37-41).
    def delete_medicare(dfn, eligibility_mien:, client: RpmsRpc.client)
      multiple = positive_ien!(eligibility_mien, "eligibility_mien")
      return nil unless canonical_dfn(dfn)

      medicare_update(dfn, proc: "D", definition: MEDICARE_ELIGIBILITY_WINDOW,
                      mien: multiple, client: client)
    end
    shape :delete_medicare, resource: "coverages", verb: "DELETE", path: "/patients/{dfn}/coverages/medicare"

    # Remove ^AUPNMCR(DFN) only when #9000003.11 has no eligibility rows.
    # Otherwise { success: false, error: :eligibility_rows_remain } and the
    # header delete is not sent. An unreadable list is the same refusal.
    def delete_medicare_record(dfn, client: RpmsRpc.client)
      id = canonical_dfn(dfn)
      return nil unless id

      listed = medicare_eligibility_rows(id)
      if listed.nil? || listed[:error] || listed[:entries].any?
        return { success: false, error: :eligibility_rows_remain,
                 message: "medicare eligibility rows remain for patient #{id}",
                 rien: nil, mien: nil }
      end

      medicare_update(dfn, proc: "D", definition: MEDICARE_WINDOW, client: client)
    end
    shape :delete_medicare_record, resource: "coverages", verb: "DELETE",
          path: "/patients/{dfn}/coverages/medicare-record"

    # Lay in a Medicaid record (PROC A, RIEN blank), then an eligibility row
    # on that record with the effective date and coverage type. record_ien
    # and multiple_ien are the eligibility reply's pieces 3 and 4. A blank
    # or non-positive multiple IEN is failure. When the eligibility row does
    # not file, the record this call just created is removed.
    def add_medicaid(dfn, effective_on:, coverage: "FULL", client: RpmsRpc.client)
      eligibility_params = { "AGGMDESD" => effective_on, "AGGMDECV" => coverage }
      validate_window_params!(MEDICAID_ELIGIBILITY_WINDOW, eligibility_params)
      return nil unless canonical_dfn(dfn)

      header = medicaid_update(dfn, proc: "A", definition: MEDICAID_WINDOW, client: client)
      return header unless header && header[:success]

      record = header[:record_ien].to_s
      unless record.match?(CANONICAL_DFN)
        return medicaid_eligibility_failure(header, rolled_back: false)
      end

      filed = medicaid_update(dfn, proc: "A", definition: MEDICAID_ELIGIBILITY_WINDOW,
                              record_ien: record, params: eligibility_params, client: client)
      return filed if positive_piece?(filed, :multiple_ien)

      rolled = rollback_medicaid_record(dfn, record, client)
      medicaid_eligibility_failure(filed, rolled_back: rolled, record_ien: record)
    end
    shape :add_medicaid, resource: "coverages", verb: "POST", path: "/patients/{dfn}/coverages/medicaid"

    # One Medicaid Eligibility PROC D. #9000004 .01 must be this patient's
    # DFN, checked before the wire (:record_not_patients otherwise). When the
    # row was the last one, UPD^AGGUPMCD kills the #9000004 record
    # (AGGUPMCD.m:41-45). An outstanding-claims refusal is :billed_eligibility
    # and is not retried.
    def delete_medicaid(dfn, record_ien:, eligibility_mien:, client: RpmsRpc.client)
      record = positive_ien!(record_ien, "record_ien")
      multiple = positive_ien!(eligibility_mien, "eligibility_mien")
      id = canonical_dfn(dfn)
      return nil unless id
      return record_not_patients(record, multiple, id) unless medicaid_owned?(record, id)

      medicaid_update(dfn, proc: "D", definition: MEDICAID_ELIGIBILITY_WINDOW,
                      record_ien: record, multiple_ien: multiple, client: client)
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

    def positive_ien!(value, name)
      text = value.to_s
      raise ArgumentError, "#{name} must be a positive integer" unless text.match?(CANONICAL_DFN)

      text
    end

    def optional_ien!(value, name)
      text = value.to_s
      return text if text.empty?

      positive_ien!(text, name)
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

    def validate_window_params!(window, params)
      allowed = WINDOW_FIELDS[window]
      return unless allowed

      (params || {}).each do |name, value|
        next if value.nil?

        key = wire!(name)
        raise ArgumentError, "unknown coverage parameter #{key}" unless allowed.include?(key)

        text = wire!(value)
        next unless DATE_FIELDS.include?(key)
        raise ArgumentError, "#{key} must be a real MM/DD/YYYY date" unless calendar_date?(text)
      end
    end

    def calendar_date?(text)
      return false unless text.match?(CALENDAR_DATE)

      parsed = Date.strptime(text, "%m/%d/%Y")
      parsed.strftime("%m/%d/%Y") == text
    rescue ArgumentError
      false
    end

    def positive_piece?(result, key)
      result.is_a?(Hash) && result[:success] && result[key].to_s.match?(CANONICAL_DFN)
    end

    def medicare_eligibility_failure(result, rolled_back:)
      body = result.is_a?(Hash) ? result : {}
      { success: false, error: :eligibility_failed, rolled_back: rolled_back == true,
        message: body[:message].to_s, rien: body[:rien], mien: body[:mien] }
    end

    def medicaid_eligibility_failure(result, rolled_back:, record_ien: nil)
      body = result.is_a?(Hash) ? result : {}
      { success: false, error: :eligibility_failed, rolled_back: rolled_back == true,
        message: body[:message].to_s,
        record_ien: body[:record_ien].to_s.empty? ? record_ien.to_s : body[:record_ien].to_s,
        multiple_ien: body[:multiple_ien].to_s }
    end

    def rollback_medicare_header(dfn, client)
      gone = delete_medicare_record(dfn, client: client)
      gone.is_a?(Hash) && gone[:success] == true
    end

    def rollback_medicaid_record(dfn, record, client)
      gone = medicaid_update(dfn, proc: "D", definition: MEDICAID_WINDOW, record_ien: record, client: client)
      gone.is_a?(Hash) && gone[:success] == true
    end

    def record_not_patients(record, multiple, dfn)
      { success: false, error: :record_not_patients,
        message: "medicaid record #{record} does not belong to patient #{dfn}",
        record_ien: record, multiple_ien: multiple }
    end

    # #9000003.11 is a subfile. LIST^DIC with no parent IENS is refused
    # ("File# 9000003.11 and IEN string , represent different subfile levels",
    # DDR.m / LIST^DIC). ",DFN," is the list of that patient's rows. A PART
    # list that FileMan actually answers is kept; a refusal or no reply is
    # asked again with the parent IENS. Header delete waits on a confirmed
    # empty list.
    def medicare_eligibility_rows(dfn)
      listed = list_medicare_eligibility(part: dfn)
      return listed if listed.is_a?(Hash) && !listed[:error]

      list_medicare_eligibility(iens: ",#{dfn},")
    end

    def list_medicare_eligibility(iens: nil, part: nil)
      ContextScope.scoped(RpmsRpc.client, FILEMAN_CONTEXT) do
        DdrFileman.lister(file: MEDICARE_ELIGIBILITY_FILE, iens: iens, fields: "@;.01", flags: "IP", part: part)
      end
    end

    def medicare_header_absent?(dfn)
      got = fileman_entry(MEDICARE_FILE, "#{dfn},")
      return false if got.nil?

      got[:error] || got.dig(:fields, ".01", :internal).to_s.strip.empty?
    end

    def medicaid_owned?(record_ien, dfn)
      got = fileman_entry(MEDICAID_FILE, "#{record_ien},")
      return false if got.nil? || got[:error]

      got.dig(:fields, ".01", :internal).to_s.strip == dfn.to_s
    end

    def fileman_entry(file, iens)
      ContextScope.scoped(RpmsRpc.client, FILEMAN_CONTEXT) do
        DdrFileman.gets_entry(file: file, iens: iens, fields: ".01", flags: "I")
      end
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

    def typed_field_names(row)
      row.split("^").filter_map { |piece| piece[TYPED_FIELD, 1] }
    end

    def insurance_header?(row)
      names = typed_field_names(row)
      INSURANCE_HEADER.all? { |name| names.include?(name) }
    end

    def error_marker?(row)
      typed_field_names(row).include?("ERROR")
    end

    def coverage_entries(rows)
      rows.filter_map do |row|
        coverage, effective = pieces(row)
        next if coverage.empty? && effective.empty?

        { coverage: coverage, effective_on: effective }
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
        { success: false, error: medicaid_error(message), **body }
      end
    end

    def medicaid_error(message)
      return :billed_eligibility if message.to_s.match?(BILLED_ELIGIBILITY)

      :coverage_rejected
    end
  end
end
