# frozen_string_literal: true

require_relative "ddr_fileman"
require_relative "registration"

module RpmsRpc
  # Symbolic API for the IHS tribal / service-unit reads. Every read runs
  # on the generic FileMan RPCs (DDR GETS ENTRY DATA / DDR LISTER /
  # DDR VALIDATOR via RpmsRpc::DdrFileman) over the real files — the
  # invented placeholder wire names that used to back this module are
  # removed (docs/RPC_COVERAGE.md provenance notes).
  #
  # Files and fields (file numbers verified against the FOIA data
  # dictionary; #9000001 field numbers against the live DD cited in
  # rpms-ops docs/REGISTRATION_RPC_CONTRACTS.md §5 and the AG field maps,
  # AGED1.m/AGED2.m):
  #
  #   #9000001    IHS PATIENT (^AUPNPAT)
  #     .07  TRIBAL ENROLLMENT NO.       (AGED2.m field map)
  #     1108 TRIBE OF MEMBERSHIP         (pointer → TRIBE #9999999.03)
  #     1109 TRIBE QUANTUM               (AGED2.m field map)
  #     1110 INDIAN BLOOD QUANTUM        (AGED2.m field map)
  #     1111 CLASSIFICATION/BENEFICIARY  (pointer → BENEFICIARY #9999999.25)
  #     1112 ELIGIBILITY STATUS          (set I/D/C/P per the live DD)
  #     1118 CURRENT COMMUNITY           (free text per the live DD)
  #   #9999999.03 TRIBE (^AUTTTRI)       — ^DIC(9999999.03,0); .01 NAME,
  #     .02 tribe code (read via .02 in the ACD* routines; node-0 piece 2
  #     per TRIBE^AUPNPAT3)
  #   #9999999.22 SERVICE UNIT (^AUTTSU) — ^DIC(9999999.22,0); .01 NAME.
  #     Other node-0 pieces have no verified field semantics yet, so only
  #     .01 is projected (pending live DD capture).
  #
  # Values come back as GETS^DIQ internal/external pairs; nothing here
  # invents response layouts — unknown semantics stay unprojected.
  module Tribal
    extend self

    TRIBE_FILE = "9999999.03"
    SERVICE_UNIT_FILE = "9999999.22"

    FIELD_ENROLLMENT_NUMBER = ".07"
    FIELD_TRIBE_QUANTUM = "1109"
    FIELD_INDIAN_BLOOD_QUANTUM = "1110"

    ENROLLMENT_FIELDS = [
      FIELD_ENROLLMENT_NUMBER,
      Registration::FIELD_TRIBE,
      FIELD_TRIBE_QUANTUM,
      FIELD_INDIAN_BLOOD_QUANTUM,
      Registration::FIELD_CLASSIFICATION,
      Registration::FIELD_ELIGIBILITY,
      Registration::FIELD_COMMUNITY
    ].join(";").freeze

    ELIGIBILITY_FIELDS = [
      Registration::FIELD_CLASSIFICATION,
      Registration::FIELD_ELIGIBILITY
    ].join(";").freeze

    # Tribal enrollment projection for a patient — GETS^DIQ over the
    # #9000001 tribal fields. Returns nil for an unknown DFN (the [ERROR]
    # marker) or when the broker gives no response.
    def enrollment(dfn)
      fields = gets_fields(Registration::PATIENT_FILE, "#{dfn},", ENROLLMENT_FIELDS)
      return nil if fields.nil?

      {
        enrollment_number:    external(fields, FIELD_ENROLLMENT_NUMBER),
        tribe_ien:            internal_ien(fields, Registration::FIELD_TRIBE),
        tribe_name:           external(fields, Registration::FIELD_TRIBE),
        tribe_quantum:        external(fields, FIELD_TRIBE_QUANTUM),
        indian_blood_quantum: external(fields, FIELD_INDIAN_BLOOD_QUANTUM),
        classification_ien:   internal_ien(fields, Registration::FIELD_CLASSIFICATION),
        classification:       external(fields, Registration::FIELD_CLASSIFICATION),
        eligibility_status:   internal(fields, Registration::FIELD_ELIGIBILITY),
        community:            external(fields, Registration::FIELD_COMMUNITY)
      }
    end

    # Eligibility projection — the 1111/1112 subset of the same read.
    # eligibility_status is the internal set code (I/D/C/P per the live
    # DD); the external form rides :eligibility_status_name. The old
    # placeholder's invented :active/:eligible_for_ihs/:benefit_package
    # keys are gone — no RPMS source defines them.
    def eligibility(dfn)
      fields = gets_fields(Registration::PATIENT_FILE, "#{dfn},", ELIGIBILITY_FIELDS)
      return nil if fields.nil?

      {
        eligibility_status:      internal(fields, Registration::FIELD_ELIGIBILITY),
        eligibility_status_name: external(fields, Registration::FIELD_ELIGIBILITY),
        classification_ien:      internal_ien(fields, Registration::FIELD_CLASSIFICATION),
        classification:          external(fields, Registration::FIELD_CLASSIFICATION)
      }
    end

    # Syntactic validation of a tribal enrollment number against the live
    # input transform of #9000001 field .07 (VAL^DIE via DDR VALIDATOR).
    # The old placeholder claimed tribe-membership validation — no such
    # server-side check exists in RPMS; format validation is what the
    # server actually offers. Returns { valid:, internal:, external: } or
    # nil (no broker response).
    def validate(enrollment_number)
      result = DdrFileman.validate_field(file: Registration::PATIENT_FILE, iens: "",
                                         field: FIELD_ENROLLMENT_NUMBER,
                                         value: enrollment_number.to_s)
      return nil unless result

      { valid: result[:valid], internal: result[:internal], external: result[:external] }
    end

    # SERVICE UNIT (#9999999.22) table entry by IEN. Only .01 NAME has
    # verified semantics; the old placeholder's per-patient signature and
    # :region key had no RPMS source (a patient's service unit derives
    # from community linkage, not a patient-file field).
    def service_unit(ien)
      fields = gets_fields(SERVICE_UNIT_FILE, "#{ien},", ".01")
      return nil if fields.nil?

      { ien: ien.to_i, name: external(fields, ".01") }
    end

    # TRIBE (#9999999.03) table entry by IEN — .01 NAME, .02 code.
    def tribe_info(ien)
      fields = gets_fields(TRIBE_FILE, "#{ien},", ".01;.02")
      return nil if fields.nil?

      { ien: ien.to_i, name: external(fields, ".01"), code: external(fields, ".02") }
    end

    # List tribes via LIST^DIC over the "B" (name) index — packed rows come
    # back IEN-first with the .01 value (V0 reply shape, LISTC^DDR).
    #   part: narrows to names starting with the given text
    #   from: resume point for paging (see DdrFileman.lister's :more)
    # Returns [{ ien:, name: }] ([] for an empty page), or nil (no broker
    # response).
    def tribes(part: nil, from: nil)
      listing = DdrFileman.lister(file: TRIBE_FILE, part: part, from: from, xref: "B")
      return nil if listing.nil?
      return [] if listing[:error]

      listing[:entries].map do |entry|
        { ien: entry[:ien].to_i, name: entry[:pieces]&.first }
      end
    end

    private

    # GETS^DIQ read → the parsed :fields hash, nil on [ERROR] / no
    # response / empty record. "IE" requests both internal and external
    # values (GETSC^DDR2 emits FILE^IEN^FIELD^INTERNAL^EXTERNAL rows).
    def gets_fields(file, iens, field_spec)
      reply = DdrFileman.gets_entry(file: file, iens: iens, fields: field_spec, flags: "IE")
      return nil if reply.nil? || reply[:error] || reply[:fields].empty?

      reply[:fields]
    end

    def external(fields, field)
      fields.dig(field, :external)
    end

    def internal(fields, field)
      fields.dig(field, :internal)
    end

    def internal_ien(fields, field)
      value = internal(fields, field)
      value.nil? || value.empty? ? nil : value.to_i
    end
  end
end
