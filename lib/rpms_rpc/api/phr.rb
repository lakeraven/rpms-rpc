# frozen_string_literal: true

require_relative "../shape"
require_relative "../fileman_date_parser"
require "date"

module RpmsRpc
  # Symbolic API for Personal Health Record and CCD gateway RPCs
  # (BEHOCCD*, BEHOCIR*). The Direct-messaging and access-log methods this
  # module once offered (`patient_direct_address`, `provider_direct_address`,
  # `facility_direct_domain`, `record_access`) sent BPHR * names no built
  # 9.0 image registers; they were removed (#207).
  #
  # `find(ien)` sent a document IEN to BEHOCIR GETTXT, which is a SNOMED CT
  # term lookup (GETTXT^BEHOCIR, BEHOCIR.m:101-108), and returned its reply
  # as the document. A CCD document is a VistA Imaging image (#2005, type
  # CCD-SUMMARY) whose content is a file on the image store; no RPC the
  # build registers returns it, so `find` was removed (#668, ADR 0008).
  module Phr
    extend self
    extend Shape::Declarable

    DEFAULT_CCD_TITLE = "Clinical Document"
    DEFAULT_CCD_TYPE = "CCD"

    def enrollment_status(dfn)
      return disabled_status("Invalid patient") if invalid_id?(dfn)

      # BEHOCCD PHR is line-based, not caret-delimited:
      #   line 0: "1" (has access) or "0" (no access)
      #   line 1: optional human-readable message
      # fetch_one normalizes to first line only, which would drop the
      # message and would fail to coerce "1Some text" forms — so the
      # parsing is done here against the raw response.
      response = RpmsRpc.client.call_rpc(DataMapper.phr_access.rpc_name, dfn.to_s)
      return disabled_status("No response") if blank_response?(response)

      lines = response.is_a?(Array) ? response : response.to_s.split(/\r?\n/)
      status = lines.first.to_s.strip
      message = lines[1].to_s.strip
      has_access = status == "1"

      {
        enrolled: has_access,
        has_access: has_access,
        message: message.empty? ? default_status_message(has_access) : message
      }
    end
    shape :enrollment_status, resource: "phr", verb: "GET", path: "/patients/{dfn}/phr/enrollment-status"

    def has_access?(dfn)
      enrollment_status(dfn)[:has_access]
    end
    shape :has_access?, resource: "phr", verb: "GET", path: "/patients/{dfn}/phr/has-access"

    # GETCCDS(DATA,DFN,STRTDT,ENDDT)^BEHOCIR1 (BEHOCIR1.m:7) takes the
    # patient and the date range as three formals, FileMan dates, and hands
    # them to GETIMGS^MAGSIXG1 as the image date range (:13). VistA Imaging's
    # MAGSIXG1 is not in the FOIA release, so a build without it answers an M
    # error, which raises Client::RpcMError (#698). The row layout below is
    # GETIMGS's, which no build here has answered; see the mapping.
    def for_patient(dfn, start_date: Date.today - 365, end_date: Date.today)
      return [] if invalid_id?(dfn)

      rows = DataMapper.ccd_document.fetch_many(dfn.to_s, FilemanDateParser.to_fileman(start_date.to_date),
                                                FilemanDateParser.to_fileman(end_date.to_date))
      Array(rows).map { |row| decorate_ccd(row) }
    end
    shape :for_patient, resource: "phr", verb: "GET", path: "/patients/{dfn}/phr"

    def counts(dfn)
      return zero_counts if invalid_id?(dfn)

      row = DataMapper.immunization_count.fetch_one(dfn.to_s)
      return zero_counts if row.nil?

      total = row[:total].to_i
      reconciled = row[:reconciled].to_i
      { total: total, reconciled: reconciled, pending: total - reconciled }
    end
    shape :counts, resource: "phr", verb: "GET", path: "/patients/{dfn}/phr/counts"

    def referrals_for_visits(visit_iens)
      ids = Array(visit_iens).reject { |ien| invalid_id?(ien) }
      return [] if ids.empty?

      DataMapper.ccd_referral.fetch_many(ids.join("^"))
    end
    shape :referrals_for_visits, resource: "phr", verb: "GET", path: "/phr/referrals"

    private

    def decorate_ccd(row)
      row.merge(
        title: blank?(row[:title]) ? DEFAULT_CCD_TITLE : row[:title],
        type: blank?(row[:type]) ? DEFAULT_CCD_TYPE : row[:type]
      )
    end

    def zero_counts
      { total: 0, reconciled: 0, pending: 0 }
    end

    def disabled_status(message)
      { enrolled: false, has_access: false, message: message }
    end

    def default_status_message(has_access)
      has_access ? "PHR access enabled" : "PHR not enrolled"
    end

    def invalid_id?(value)
      blank?(value) || value.to_i <= 0
    end

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end

    def blank_response?(response)
      response.nil? || (response.respond_to?(:empty?) && response.empty?)
    end
  end
end
