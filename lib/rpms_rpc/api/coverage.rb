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
  # header (AGGUPMCR.m:37-41). delete_medicare never sends that: it deletes one
  # eligibility row, and refuses :no_medicare when #9000003 has no header.
  # delete_medicare_record lists #9000003.11 with IENS ",DFN," only (no PART)
  # and sends the header delete only when that list is empty and the header
  # is present. A list that cannot be read, or that still has rows, is
  # :verification_failed and sends nothing. add_medicare never deletes a
  # header: an eligibility failure is :eligibility_failed, rolled_back false,
  # header_left true.
  #
  # medicare_update and medicaid_update are module-internal. Each is pinned to
  # its two windows (Medicare / Medicare Eligibility, Medicaid / Medicaid
  # Eligibility). RIEN and MIEN are positional arguments, not PARMS names.
  #
  # Names in PARMS must be on the window's allowlist, which is the
  # ^AGG(9009068.3) "AC" index without RIEN and MIEN (UPD refuses any other
  # name, AGGUPMCR.m:70-71 and AGGUPMCD.m:68-69). A type D parameter is a
  # calendar date; PARS passes it through $$DATE^AGGUL1 (AGGUPMCR.m:286,
  # AGGUPMCD PARS). Dates are refused unless they are a real MM/DD/YYYY. A
  # value containing "=", "OVERRIDE" (any case), a caret, $C(28), or another
  # ASCII control is refused before any RPC. An invalid DFN makes no call.
  #
  # Guard FileMan reads (header, ownership, eligibility rows) run on the
  # client: passed to the write. A read that does not answer, an ownership
  # mismatch, and an eligibility list that is not a confirmed empty list are
  # :verification_failed. A Medicare header FileMan error or blank .01 is
  # :no_medicare (that is how a missing ^AUPNMCR(DFN) answers).
  module Coverage
    extend self
    extend Shape::Declarable

    EMPTY = { entries: [].freeze }.freeze

    # ^AGG(9009068.3,"B",…) window names.
    MEDICARE_WINDOW = "Medicare" # IEN 11, file 9000003
    MEDICARE_ELIGIBILITY_WINDOW = "Medicare Eligibility" # IEN 13, file 9000003.11
    MEDICAID_WINDOW = "Medicaid" # IEN 10, file 9000004
    MEDICAID_ELIGIBILITY_WINDOW = "Medicaid Eligibility" # IEN 12, file 9000004.11

    # Each AGG writer is pinned to these two windows and no others.
    MEDICARE_WINDOWS = [ MEDICARE_WINDOW, MEDICARE_ELIGIBILITY_WINDOW ].freeze
    MEDICAID_WINDOWS = [ MEDICAID_WINDOW, MEDICAID_ELIGIBILITY_WINDOW ].freeze

    MEDICARE_FILE = "9000003"
    MEDICARE_ELIGIBILITY_FILE = "9000003.11"
    MEDICAID_FILE = "9000004"
    PRIVATE_ELIGIBILITY_FILE = "9000006.11"

    # PARMS names for each window. RIEN and MIEN are the positional IEN
    # arguments and are not allowed here. Type D names are calendar dates.
    # The rest are the ^AGG(9009068.3) "AC" index on the pinned build.
    WINDOW_FIELDS = {
      MEDICARE_WINDOW => %w[
        AGGLSTDT AGGMCABN AGGMCCCF AGGMCCRD AGGMCDOB AGGMCIMP AGGMCINS AGGMCNME
        AGGMCNUM AGGMCPCP AGGMCQMB AGGMCROI AGGMCSTS AGGMCSUF MCELIG SEQNBR
      ].freeze,
      MEDICARE_ELIGIBILITY_WINDOW => %w[
        AGGMCCOV AGGMCEED AGGMCESD AGGMCG AGGMCGN AGGMCIDN AGGMCMN AGGMCPC
        AGGMCPN AGGMRDOB
      ].freeze,
      MEDICAID_WINDOW => %w[
        AGGLSTDT AGGMDCCF AGGMDCRD AGGMDDOB AGGMDEED AGGMDESD AGGMDGRN AGGMDGRP
        AGGMDINM AGGMDINS AGGMDNME AGGMDNUM AGGMDPCP AGGMDPLN AGGMDRCD AGGMDREL
        AGGMDSTE AGGMDSTS MDELIG SEQNBR
      ].freeze,
      MEDICAID_ELIGIBILITY_WINDOW => %w[AGGMDECV AGGMDEED AGGMDESD].freeze
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

    # AG's own reads of a patient's coverage: the RPCs the AG registration
    # client fills its Medicaid, Medicare and Private Insurance windows with.
    WINDOW_MANY_RPC = "AGG BUILD WINDOW MANY"         # MANY^AGGPTDMG
    WINDOW_DISPLAY_RPC = "AGG BUILD WINDOW DISPLAY"   # BLD^AGGWDISP
    WINDOW_MULTIPLE_RPC = "AGG BUILD WINDOW MULTIPLE" # MUL^AGGPTDMG
    PRIVATE_RPC = "AGG UPDATE PRIVATE INSUR"          # UPD^AGGUPPVT
    INSURERS_RPC = "AGG GET INSURANCE DATA"           # GET^AGGINSUR

    PRIVATE_INSURANCE_WINDOW = "Private Insurance" # IEN 14, file 9000006.11 (read)
    # Each window's eligibility rows sit under node 11 of their record
    # (^AUPNMCD(RIEN,11), ^AUPNMCR(DFN,11), ^AUPNPRVT(DFN,11)).
    ELIGIBILITY_NODE = "11"

    # "Insurance Edit" (IEN 45) parameters add_private_insurance sends (the
    # window's "AC" index; AGGUPPVT.m PARS). AGGPIINS and AGGPIREL are IENs.
    PRIVATE_FIELDS = %w[
      AGGPIINS AGGPIHLN AGGPINUM AGGPIMBN AGGPIREL AGGPIESD AGGPIEED AGGPHESD AGGPHEED
    ].freeze
    PRIVATE_DATE_FIELDS = %w[AGGPIESD AGGPIEED AGGPHESD AGGPHEED].freeze

    # Medicare coverage types, as the Medicare Eligibility window's choices name them.
    MEDICARE_PARTS = { "A" => "PART A", "B" => "PART B", "D" => "PART D" }.freeze

    # AG's display of a date: "JAN 1,2026" ($$FMTE^AGGUL1).
    AG_DATE = /\A[A-Z]{3} \d{1,2},\d{4}\z/
    # AG's in-force answer for a record (MCDACT/MCRACT/PVTACT^AGGARVAL):
    # some eligibility row covers today.
    ACTIVE = "ACTIVE"

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

    # UPD^AGGUPMCR, module-internal. Pinned to Medicare and Medicare Eligibility.
    # Returns { success:, error:, message:, rien:, mien: }, or nil when the
    # broker returns nothing that can be read as a reply. rien is the patient
    # IEN (integer when the piece is digits). mien is the eligibility multiple
    # IEN as text. A non-blank mien must be a positive integer. params are
    # limited to the window's allowlist (no RIEN, no MIEN).
    def medicare_update(dfn, proc:, definition:, mien: "", params: {}, client: RpmsRpc.client)
      procedure = require_proc!(proc)
      window = pinned_window!(definition, MEDICARE_WINDOWS)
      multiple = optional_ien!(mien, "mien")
      validate_window_params!(window, params)
      encoded = encode_params(params || {})
      id = canonical_dfn(dfn)
      return nil unless id

      scoped(client, AGG_CONTEXT) do
        finish_medicare(call_array(client, MEDICARE_RPC, id, procedure, window, multiple, encoded))
      end
    end

    # UPD^AGGUPMCD, module-internal. Pinned to Medicaid and Medicaid Eligibility.
    # record_ien is the #9000004 IEN (not the DFN); on PROC A with record_ien
    # blank the routine lays a new record in with FILE^DICN. Returns
    # { success:, error:, message:, record_ien:, multiple_ien: }, or nil on an
    # empty reply. A non-blank record or multiple IEN must be a positive
    # integer. An outstanding-claims refusal is :billed_eligibility.
    def medicaid_update(dfn, proc:, definition:, record_ien: "", multiple_ien: "", params: {}, client: RpmsRpc.client)
      procedure = require_proc!(proc)
      window = pinned_window!(definition, MEDICAID_WINDOWS)
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
    private :medicare_update, :medicaid_update

    # File the Medicare header (name, number, suffix, release-of-information
    # date), then a Medicare Eligibility row dated effective_on. The returned
    # rien and mien come from the eligibility reply (pieces 3 and 4). A blank
    # or non-positive mien is failure. The header is never deleted from here:
    # an eligibility failure leaves it and reports header_left.
    #
    # ends_on: (MM/DD/YYYY) files the eligibility end date (#9000003.11 .02)
    # and part: the coverage type (.03: A, B or D), both on the same row.
    def add_medicare(dfn, roi_on:, name:, number:, suffix: nil, effective_on:, ends_on: nil, part: nil,
                     client: RpmsRpc.client)
      header_params = {
        "AGGMCROI" => roi_on,
        "AGGMCNME" => name,
        "AGGMCNUM" => number,
        "AGGMCSUF" => suffix
      }
      eligibility_params = { "AGGMCESD" => effective_on }.merge({ "AGGMCEED" => ends_on, "AGGMCCOV" => medicare_part(part) }.compact)
      validate_window_params!(MEDICARE_WINDOW, header_params)
      validate_window_params!(MEDICARE_ELIGIBILITY_WINDOW, eligibility_params)
      return nil unless canonical_dfn(dfn)

      filed = medicare_update(dfn, proc: "A", definition: MEDICARE_WINDOW, params: header_params, client: client)
      return filed unless filed && filed[:success]

      filed_eligibility = medicare_update(dfn, proc: "A", definition: MEDICARE_ELIGIBILITY_WINDOW,
                                          params: eligibility_params, client: client)
      return filed_eligibility if positive_piece?(filed_eligibility, :mien)

      medicare_eligibility_failure(filed_eligibility)
    end
    shape :add_medicare, resource: "coverages", verb: "POST", path: "/patients/{dfn}/coverages/medicare"

    # One Medicare Eligibility PROC D, MIEN set. Never a MIEN-blank header
    # delete — that is delete_medicare_record, and only when no eligibility
    # rows remain (AGGUPMCR.m:37-41). :no_medicare when #9000003 has no header;
    # a header read that does not answer is :verification_failed. Neither
    # sends the AGG call.
    def delete_medicare(dfn, eligibility_mien:, client: RpmsRpc.client)
      multiple = positive_ien!(eligibility_mien, "eligibility_mien")
      id = canonical_dfn(dfn)
      return nil unless id

      case medicare_header_status(id, client)
      when :present
        medicare_update(dfn, proc: "D", definition: MEDICARE_ELIGIBILITY_WINDOW,
                        mien: multiple, client: client)
      when :absent
        no_medicare(id)
      else
        verification_failed("medicare header for patient #{id} could not be read", rien: nil, mien: multiple)
      end
    end
    shape :delete_medicare, resource: "coverages", verb: "DELETE", path: "/patients/{dfn}/coverages/medicare"

    # Remove ^AUPNMCR(DFN) only when the header is present and #9000003.11,
    # listed with IENS ",DFN,", has no eligibility rows. No header is
    # :no_medicare. A list that errors, does not answer, or still has rows is
    # :verification_failed. Neither refusal sends the header delete.
    def delete_medicare_record(dfn, client: RpmsRpc.client)
      id = canonical_dfn(dfn)
      return nil unless id

      case medicare_header_status(id, client)
      when :absent
        return no_medicare(id)
      when :unreadable
        return verification_failed("medicare header for patient #{id} could not be read", rien: nil, mien: nil)
      end

      listed = medicare_eligibility_rows(id, client)
      if !listed.is_a?(Hash) || listed[:error] || listed[:entries].any?
        return verification_failed("medicare eligibility rows for patient #{id} could not be confirmed empty",
                                   rien: nil, mien: nil)
      end

      medicare_update(dfn, proc: "D", definition: MEDICARE_WINDOW, client: client)
    end
    shape :delete_medicare_record, resource: "coverages", verb: "DELETE",
          path: "/patients/{dfn}/coverages/medicare-record"

    # Lay in a Medicaid record (PROC A, RIEN blank), then an eligibility row
    # on that record with the effective date and coverage type. record_ien
    # and multiple_ien are the eligibility reply's pieces 3 and 4. A blank
    # or non-positive multiple IEN is failure. When the header step returns
    # no record IEN, the result is :record_ien_missing and nothing else is
    # sent. When the eligibility row does not file, the record IEN the header
    # step returned is deleted (PROC D) without a read-back; it is the IEN
    # this call was just handed, not one the caller supplied.
    #
    # number: is the Medicaid number (#9000004 .03) and state_ien: the STATE
    # (#5) IEN the number was issued by (.04); both file on the record, in the
    # header step. ends_on: (MM/DD/YYYY) is the eligibility end date (.02 of
    # the row). AG files the insurer itself (MEDICAID, AGGUPMCD.m MCD).
    def add_medicaid(dfn, effective_on:, ends_on: nil, coverage: "FULL", number: nil, state_ien: nil,
                     client: RpmsRpc.client)
      header_params = { "AGGMDNUM" => number, "AGGMDSTE" => state_ien && positive_ien!(state_ien, "state_ien") }
                      .compact
      eligibility_params = { "AGGMDESD" => effective_on }.merge({ "AGGMDEED" => ends_on, "AGGMDECV" => coverage }.compact)
      validate_window_params!(MEDICAID_WINDOW, header_params)
      validate_window_params!(MEDICAID_ELIGIBILITY_WINDOW, eligibility_params)
      return nil unless canonical_dfn(dfn)

      header = medicaid_update(dfn, proc: "A", definition: MEDICAID_WINDOW, params: header_params, client: client)
      return header unless header && header[:success]

      record = header[:record_ien].to_s
      return record_ien_missing(header) unless record.match?(CANONICAL_DFN)

      begin
        filed = medicaid_update(dfn, proc: "A", definition: MEDICAID_ELIGIBILITY_WINDOW,
                                record_ien: record, params: eligibility_params, client: client)
      rescue StandardError => e
        # The row may or may not have been filed. The record is not deleted
        # on a guess; the caller keeps the IEN for delete_medicaid.
        return eligibility_outcome_unknown(e, record)
      end
      return filed if positive_piece?(filed, :multiple_ien)

      rolled, rollback_error = attempt_rollback(dfn, record, client)
      medicaid_eligibility_failure(filed, rolled_back: rolled, record_ien: record, rollback_error: rollback_error)
    end
    shape :add_medicaid, resource: "coverages", verb: "POST", path: "/patients/{dfn}/coverages/medicaid"

    # One Medicaid Eligibility PROC D. #9000004 .01 must be this patient's
    # DFN, checked on the same client before the wire. A mismatch or a read
    # that does not answer is :verification_failed and sends nothing. When
    # the row was the last one, UPD^AGGUPMCD kills the #9000004 record
    # (AGGUPMCD.m:41-45). An outstanding-claims refusal is :billed_eligibility
    # and is not retried.
    def delete_medicaid(dfn, record_ien:, eligibility_mien:, client: RpmsRpc.client)
      record = positive_ien!(record_ien, "record_ien")
      multiple = positive_ien!(eligibility_mien, "eligibility_mien")
      id = canonical_dfn(dfn)
      return nil unless id
      unless medicaid_owned?(record, id, client)
        return verification_failed("medicaid record #{record} could not be verified for patient #{id}",
                                   record_ien: record, multiple_ien: multiple)
      end

      medicaid_update(dfn, proc: "D", definition: MEDICAID_ELIGIBILITY_WINDOW,
                      record_ien: record, multiple_ien: multiple, client: client)
    end
    shape :delete_medicaid, resource: "coverages", verb: "DELETE",
          path: "/patients/{dfn}/coverages/records/{record_ien}/medicaid"

    # The patient's coverage as AG's registration windows show it: one
    # entry per Medicaid record, Medicare record and private policy, each
    # with its payer, member number, eligibility rows and AG's own
    # active/inactive answer for today (MCDACT/MCRACT/PVTACT^AGGARVAL).
    #
    #   { medicaid: [{ record_ien:, payer:, number:, state:, active:,
    #                  eligibility: [{ ien:, starts_on:, ends_on:, coverage: }] }],
    #     medicare: [{ record_ien:, payer:, number:, suffix:, active:,
    #                  eligibility: [{ ien:, starts_on:, ends_on:, coverage: }] }],
    #     private:  [{ record_ien:, payer:, payer_ien:, number:, policy_holder:,
    #                  starts_on:, ends_on:, active: }] }
    #
    # Dates are Date or nil. nil (never a partial answer) when the DFN is not
    # a positive integer or any window read gives no reply in AG's typed form.
    def on_file(dfn, client: RpmsRpc.client)
      id = canonical_dfn(dfn)
      return nil unless id

      found = scoped(client, AGG_CONTEXT) do
        medicaid = medicaid_on_file(id, client)
        medicare = medicare_on_file(id, client)
        private_rows = window_rows(client, WINDOW_MULTIPLE_RPC, PRIVATE_INSURANCE_WINDOW, ELIGIBILITY_NODE, id, "")
        next nil if medicaid.nil? || medicare.nil? || private_rows.nil?

        { medicaid: medicaid, medicare: medicare, private: private_rows }
      end
      return nil if found.nil?

      policies = found[:private].map { |row| private_entry(row, id, client) }
      return nil if policies.any?(&:nil?)

      found.merge(private: policies)
    end
    shape :on_file, resource: "coverages", verb: "GET", path: "/patients/{dfn}/coverages/on-file"

    # The insurers on file (#9999999.18) as AG lists them for its insurer
    # pick: [{ ien:, name:, city:, state:, status:, type: }], or nil when
    # the reply is not AG's typed list.
    def insurers(client: RpmsRpc.client)
      rows = scoped(client, AGG_CONTEXT) { typed_rows(call_array(client, INSURERS_RPC, "")) }
      return nil if rows.nil?

      rows.map do |row|
        { ien: row["IEN"], name: row["NAME"], city: row["CITY"], state: row["STATE"],
          status: row["STATUS"], type: row["TYPE"] }
      end
    end
    shape :insurers, resource: "coverages", verb: "GET", path: "/coverages/insurers"

    # A private policy through AG's "Insurance Edit" window (UPD^AGGUPPVT):
    # the patient's #9000006.11 row for the insurer, with the member number
    # (21) and eligibility dates (.06/.07), and its POLICY HOLDER (#9000003.1)
    # found by name for that insurer or added (AGGUPPVT.m:46-59). The holder's
    # effective and expiration dates (.17/.18) are sent too: AG's window shows
    # those, and for a SELF member copies them onto the row (UPOL).
    #
    # Returns { success: true, record_ien:, policy_holder_ien: } or
    # { success: false, error: :coverage_rejected, message: }; nil on no reply.
    def add_private_insurance(dfn, insurer_ien:, policy_holder:, member_number:, effective_on:,
                              policy_number: nil, ends_on: nil, relationship_ien: nil, client: RpmsRpc.client)
      params = {
        "AGGPIINS" => positive_ien!(insurer_ien, "insurer_ien"),
        "AGGPIHLN" => policy_holder,
        "AGGPINUM" => policy_number,
        "AGGPIMBN" => member_number,
        "AGGPIREL" => relationship_ien && positive_ien!(relationship_ien, "relationship_ien"),
        "AGGPIESD" => effective_on,
        "AGGPIEED" => ends_on,
        "AGGPHESD" => effective_on,
        "AGGPHEED" => ends_on
      }.compact
      validate_private_params!(params)
      id = canonical_dfn(dfn)
      return nil unless id

      scoped(client, AGG_CONTEXT) do
        finish_private(call_array(client, PRIVATE_RPC, "A", id, "", "", encode_params(params)))
      end
    end
    shape :add_private_insurance, resource: "coverages", verb: "POST", path: "/patients/{dfn}/coverages/private-insurance"

    # $C(28)-delimited NAME=VALUE, the PARMS string both AGG updates take.
    # nil values are dropped. "=", "OVERRIDE" (any case), a caret, $C(28),
    # or another ASCII control in a name or a value is refused — nothing is sent.
    def encode_params(params)
      pairs = (params || {}).reject { |_, value| value.nil? }.map { |name, value| [ wire!(name), wire!(value) ] }
      pairs.map { |name, value| "#{name}=#{value}" }.join(PARM_DELIM)
    end

    private

    def medicare_part(part)
      return nil if part.nil?

      MEDICARE_PARTS.fetch(part.to_s.strip.upcase.delete_prefix("PART ")) do
        raise ArgumentError, "part must be A, B or D"
      end
    end

    def validate_private_params!(params)
      %w[AGGPIHLN AGGPIMBN AGGPIESD].each do |key|
        raise ArgumentError, "#{key} is required" if params[key].to_s.strip.empty?
      end
      params.each do |key, value|
        raise ArgumentError, "unknown private insurance parameter #{key}" unless PRIVATE_FIELDS.include?(key)

        text = wire!(value)
        if PRIVATE_DATE_FIELDS.include?(key) && !calendar_date?(text)
          raise ArgumentError, "#{key} must be a real MM/DD/YYYY date"
        end
      end
    end

    def finish_private(raw)
      row = result_pieces(raw)
      return nil if row.nil?
      if row == :header_only
        return { success: false, error: :coverage_empty_reply, message: "coverage reply carried no data record" }
      end

      result, message, record_ien, holder_ien = row
      return { success: false, error: :coverage_rejected, message: message.to_s } unless result == "1"

      { success: true, error: nil, record_ien: record_ien.to_s, policy_holder_ien: holder_ien.to_s }
    end

    # Medicaid records (MANY, "B" index on DFN), each with its eligibility
    # rows (MULTIPLE under the record). nil when a read does not answer.
    def medicaid_on_file(dfn, client)
      records = window_rows(client, WINDOW_MANY_RPC, MEDICAID_WINDOW, "B", dfn)
      return nil if records.nil?

      records.map do |row|
        record = row["RIEN"]
        rows = window_rows(client, WINDOW_MULTIPLE_RPC, MEDICAID_ELIGIBILITY_WINDOW, ELIGIBILITY_NODE, record, "")
        return nil if rows.nil?

        { record_ien: record, payer: external(row["AGGMDINS"]), number: row["AGGMDNUM"],
          state: external(row["AGGMDSTE"]), active: row["AGGMDSTS"] == ACTIVE,
          eligibility: rows.map { |elig| eligibility_entry(elig, "AGGMDESD", "AGGMDEED", "AGGMDECV") } }
      end
    end

    # The Medicare record is DINUM to the patient: one at most. The window
    # answers one blank row when there is none.
    def medicare_on_file(dfn, client)
      records = window_rows(client, WINDOW_DISPLAY_RPC, MEDICARE_WINDOW, dfn)
      return nil if records.nil?

      records = records.reject { |row| row["AGGMCNUM"].to_s.empty? && external(row["AGGMCINS"]).empty? }
      return [] if records.empty?

      rows = window_rows(client, WINDOW_MULTIPLE_RPC, MEDICARE_ELIGIBILITY_WINDOW, ELIGIBILITY_NODE, dfn, "")
      return nil if rows.nil?

      records.map do |row|
        { record_ien: dfn, payer: external(row["AGGMCINS"]), number: row["AGGMCNUM"],
          suffix: external(row["AGGMCSUF"]), active: row["AGGMCSTS"] == ACTIVE,
          eligibility: rows.map { |elig| eligibility_entry(elig, "AGGMCESD", "AGGMCEED", "AGGMCCOV") } }
      end
    end

    # AG's Private Insurance window shows the policy holder's dates and
    # blanks an expiration date still to come (PVID^AGGUL2), so the member's
    # own eligibility dates (#9000006.11 .06/.07, what PVTACT^AGGARVAL judges
    # first) are read from FileMan. nil when that read does not answer.
    def private_entry(row, dfn, client)
      record = row["AGGPIIEN"].to_s
      return nil unless record.match?(CANONICAL_DFN)

      got = fileman_read(client) do
        DdrFileman.gets_entry(file: PRIVATE_ELIGIBILITY_FILE, iens: "#{record},#{dfn},", fields: ".06;.07", flags: "I")
      end
      return nil if got.nil? || got[:error]

      { record_ien: record, payer: external(row["AGGPIINS"]), payer_ien: internal(row["AGGPIINS"]),
        number: row["AGGPIMBN"], policy_holder: row["AGGPIHLN"],
        starts_on: fm_date(got.dig(:fields, ".06", :internal)), ends_on: fm_date(got.dig(:fields, ".07", :internal)),
        active: row["AGGPISTS"] == ACTIVE }
    end

    # A FileMan internal date (CYYMMDD), or nil.
    def fm_date(value)
      text = value.to_s
      return nil unless text.match?(/\A\d{7}\z/)

      Date.new(text[0, 3].to_i + 1700, text[3, 2].to_i, text[5, 2].to_i)
    rescue Date::Error
      nil
    end

    def eligibility_entry(row, starts, ends, coverage)
      { ien: row["MIEN"], starts_on: ag_date(row[starts]), ends_on: ag_date(row[ends]),
        coverage: external(row[coverage]) }
    end

    # One AG window read: its data rows as { PARAMETER => value }, or nil when
    # the reply has no typed header.
    def window_rows(client, rpc, *params)
      typed_rows(call_array(client, rpc, *params))
    end

    def typed_rows(raw)
      rows = framed_rows(raw)
      return nil if rows.nil? || rows.empty?

      names = rows.first.split("^", -1).map { |piece| piece[TYPED_FIELD, 1] }
      return nil if names.empty? || names.any?(&:nil?)

      rows.drop(1).map { |row| names.zip(row.split("^", -1).map(&:strip)).to_h }
    end

    # A coded window value is "internal$C(28)external"; plain text is both.
    def external(value)
      text = value.to_s
      text.include?(PARM_DELIM) ? text.split(PARM_DELIM, 2).last.to_s : text
    end

    def internal(value)
      value.to_s.split(PARM_DELIM, 2).first.to_s
    end

    def ag_date(value)
      text = value.to_s.strip
      return nil unless text.match?(AG_DATE)

      Date.strptime(text, "%b %d,%Y")
    rescue Date::Error
      nil
    end

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

    def pinned_window!(definition, allowed)
      window = wire!(definition)
      raise ArgumentError, "coverage window must be one of #{allowed.join(', ')}" unless allowed.include?(window)

      window
    end

    def wire!(value)
      text = value.to_s
      if text.include?(PARM_DELIM)
        raise ArgumentError, "coverage parameters must not contain the parameter delimiter"
      end
      raise ArgumentError, "coverage parameters must not contain a caret" if text.include?("^")
      raise ArgumentError, "coverage parameters must not contain '='" if text.include?("=")
      raise ArgumentError, "coverage parameters must not contain OVERRIDE" if text.match?(/override/i)
      raise ArgumentError, "coverage parameters must not contain a control character" if text.match?(CONTROL)
      raise ArgumentError, "coverage parameters must not be the FileMan delete sentinel '@'" if text.strip == "@"

      text
    end

    def validate_window_params!(window, params)
      allowed = WINDOW_FIELDS[window]
      return unless allowed

      (params || {}).each do |name, value|
        key = wire!(name)
        raise ArgumentError, "unknown coverage parameter #{key}" unless allowed.include?(key)

        if value.nil?
          raise ArgumentError, "#{key} must be a real MM/DD/YYYY date, not nil" if DATE_FIELDS.include?(key)

          next
        end

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

    def medicare_eligibility_failure(result)
      body = result.is_a?(Hash) ? result : {}
      { success: false, error: :eligibility_failed, rolled_back: false, header_left: true,
        message: body[:message].to_s, rien: body[:rien], mien: body[:mien] }
    end

    def medicaid_eligibility_failure(result, rolled_back:, record_ien: nil, rollback_error: nil)
      body = result.is_a?(Hash) ? result : {}
      failure = { success: false, error: :eligibility_failed, rolled_back: rolled_back == true,
                  message: body[:message].to_s,
                  record_ien: body[:record_ien].to_s.empty? ? record_ien.to_s : body[:record_ien].to_s,
                  multiple_ien: body[:multiple_ien].to_s }
      failure[:rollback_error] = rollback_error if rollback_error
      failure
    end

    # The eligibility call raised after the header returned a record IEN, so
    # whether the row filed is unknown. Never success; nothing is deleted.
    def eligibility_outcome_unknown(error, record)
      { success: false, error: :eligibility_outcome_unknown, rolled_back: false,
        message: "#{error.class}: #{error.message}", record_ien: record.to_s, multiple_ien: "" }
    end

    # [rolled_back, error_text]. A raise from the rollback is reported, not lost.
    def attempt_rollback(dfn, record, client)
      [ rollback_medicaid_record(dfn, record, client), nil ]
    rescue StandardError => e
      [ false, "#{e.class}: #{e.message}" ]
    end

    # PROC D on the Medicaid window for the record IEN the header step
    # returned, and only that IEN. No read confirms the record first. A blank
    # or non-canonical RIEN is not a rollback. The
    # caller-supplied IEN path is delete_medicaid, which reads #9000004 .01
    # on the same client before it deletes.
    def rollback_medicaid_record(dfn, record, client)
      owned = record.to_s
      return false unless owned.match?(CANONICAL_DFN)

      gone = medicaid_update(dfn, proc: "D", definition: MEDICAID_WINDOW, record_ien: owned, client: client)
      gone.is_a?(Hash) && gone[:success] == true
    end

    def record_ien_missing(header)
      { success: false, error: :record_ien_missing,
        message: "medicaid header did not return a record IEN",
        record_ien: header[:record_ien], multiple_ien: header[:multiple_ien] }
    end

    def no_medicare(dfn)
      { success: false, error: :no_medicare,
        message: "no medicare record for patient #{dfn}",
        rien: nil, mien: nil }
    end

    def verification_failed(message, **ids)
      { success: false, error: :verification_failed, message: message, **ids }
    end

    # #9000003.11 is a subfile. LIST^DIC with IENS ",DFN," is that patient's
    # rows (child entries under the parent). A PART list is not asked: header
    # delete waits on this one confirmed empty list.
    def medicare_eligibility_rows(dfn, client)
      fileman_read(client) do
        DdrFileman.lister(file: MEDICARE_ELIGIBILITY_FILE, iens: ",#{dfn},", fields: "@;.01", flags: "IP")
      end
    end

    # :present when #9000003 .01 is filed, :absent when FileMan errors or .01
    # is blank (no ^AUPNMCR(DFN)), :unreadable when the broker does not answer.
    def medicare_header_status(dfn, client)
      got = fileman_entry(MEDICARE_FILE, "#{dfn},", client)
      return :unreadable if got.nil?
      return :absent if got[:error] || got.dig(:fields, ".01", :internal).to_s.strip.empty?

      :present
    end

    def medicaid_owned?(record_ien, dfn, client)
      got = fileman_entry(MEDICAID_FILE, "#{record_ien},", client)
      return false if got.nil? || got[:error]

      got.dig(:fields, ".01", :internal).to_s.strip == dfn.to_s
    end

    def fileman_entry(file, iens, client)
      fileman_read(client) do
        DdrFileman.gets_entry(file: file, iens: iens, fields: ".01", flags: "I")
      end
    end

    # DdrFileman reads RpmsRpc.client. Scope the passed client for the read so
    # a guard cannot run on a different session than the write.
    def fileman_read(client, &block)
      RpmsRpc.with_client(client) do
        scoped(client, FILEMAN_CONTEXT, &block)
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

      body = raw.is_a?(Array) ? raw.map(&:to_s).join(RECORD_SEP) : raw.to_s
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
