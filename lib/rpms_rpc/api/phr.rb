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

    # Whether the patient said they use their Personal Health Record, as
    # registration last recorded it: BEHOCCD PHR answers "0" when nothing is
    # recorded, otherwise ACCESS^MM/DD/YYYY for the latest PHR ACCESS DATE
    # entry, ACCESS being 1 (yes) or 0 (no) (PHR^BEHOCCD; see the mapping).
    #
    #   enrollment_status(dfn)
    #   => { enrolled:, has_access:, answered_on: Date or nil, message: }
    #
    # It used to compare the whole line with "1", so a "1^11/20/2026" reply
    # read as not enrolled (#221).
    def enrollment_status(dfn)
      return disabled_status("Invalid patient") if invalid_id?(dfn)

      row = DataMapper.phr_access.fetch_one(dfn.to_s)
      return disabled_status("No response") if row.nil?

      has_access = row[:has_access]
      { enrolled: has_access, has_access: has_access, answered_on: answered_on(row[:answered_on]),
        message: default_status_message(has_access) }
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

    # The referrals recorded on each visit: one row per V REFERRAL entry, with
    # its RCIS referral's purpose, status, number and vendor (BEHOCCD GETREF;
    # see the mapping for the row). GETREF reads the visits as a list
    # parameter, VISITS(1), VISITS(2), ...; one "1^2" string, which this sent
    # before, is no list, so the build answered nothing for any visit (#221).
    #
    #   referrals_for_visits([visit_ien, ...])
    #   => [{ visit_ien:, referral_ien:, patient_ien:, purpose:, status:, referral_number:,
    #         vendor_fax:, vendor_direct_participant:, vendor_direct_email:, vendor_name: }, ...]
    def referrals_for_visits(visit_iens)
      ids = Array(visit_iens).reject { |ien| invalid_id?(ien) }
      return [] if ids.empty?

      DataMapper.ccd_referral.fetch_many(ids.map(&:to_s))
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
      { enrolled: false, has_access: false, answered_on: nil, message: message }
    end

    def answered_on(text)
      Date.strptime(text, "%m/%d/%Y") if text.to_s.match?(%r{\A\d\d/\d\d/\d{4}\z})
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
  end
end
