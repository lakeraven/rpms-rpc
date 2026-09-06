# frozen_string_literal: true

require_relative "../mappings"

module RpmsRpc
  # Symbolic API for ADT (Admission / Discharge / Transfer) patient-movement
  # data over ^DGPM (INPATIENT MOVEMENT #405). Engine code calls these instead
  # of referencing DataMapper mappings or RPC names directly.
  #
  # READS ONLY. There is no stock movement-WRITE RPC in the #8994 registry —
  # admit/transfer/discharge/cancel-movement have no broker-callable entry
  # point. The BPRM twin's ADT-write scenario (lakeraven-ehr#412 scenario #15)
  # therefore requires a NEW FileMan-safe (^DIE / DGPMV*) server-side RPC to be
  # authored and re-exported before those writes can be wrapped here — tracked
  # with rpms-ops#366. Until then this module exposes only the movement reads
  # that ORWPT already provides.
  module Adt
    extend self

    # A patient's admission movements — ORWPT ADMITLST (ADMITLST^ORWPT).
    # Returns an Array of
    #   { movement_datetime:, location_ien:, location:, movement_type:,
    #     movement_ien:, tiu_document_ien: }
    # ordered as the broker returns them (most recent admission first).
    def admissions(dfn)
      return [] if invalid_id?(dfn)

      DataMapper.patient_admissions.fetch_many(dfn.to_s)
    end

    # A patient's current inpatient location — ORWPT INPLOC (INPLOC^ORWPT).
    # Returns { location_ien:, ward:, ward_synonym: } when the patient is
    # currently admitted, or nil when they are not an inpatient or the DFN is
    # invalid. A leading 0 alone does NOT mean "not admitted": the routine
    # starts REC at 0 and only the HOSPITAL LOCATION piece stays 0 when the
    # ward has no 44-node link — an admitted patient on an unlinked ward
    # comes back "0^MED WARD^MW" with pieces 2-3 populated (ORWPT.m:222-227).
    # Not-admitted is "0^^" (all ward pieces empty). :location_ien is nil
    # when the ward lacks the link.
    def current_location(dfn)
      return nil if invalid_id?(dfn)

      rec = DataMapper.patient_current_location.fetch_one(dfn.to_s)
      return nil if rec.nil?

      linked = rec[:location_ien].to_i.positive?
      return nil unless linked || !rec[:ward].to_s.empty?

      rec[:location_ien] = nil unless linked
      rec
    end

    # Discharge date/time for a given admission — ORWPT DISCHARGE (DISCHRG^ORWPT).
    #   admit_datetime: the EXACT admission movement datetime — pass the
    #     :movement_datetime from admissions() through unchanged (Time
    #     round-trips; seconds are preserved when nonzero). The routine keys
    #     VAIP("D") on it, so an inexact value is a miss.
    # Returns a Time, or nil when unavailable.
    #
    # The routine cannot say "not found": it returns bare DT — TODAY,
    # date-only — both for an unknown admission (ORWPT.m:205) and for an
    # admission with no discharge yet (ORWPT.m:207). A date-only reply is
    # therefore treated as the no-data sentinel and reads as nil; real
    # discharge movement values carry a time part (+VAIP(17,1),
    # ORWPT.m:208-209). Consequence: a discharge recorded at exactly
    # midnight is indistinguishable from a miss and also reads as nil.
    def discharge_datetime(dfn, admit_datetime)
      return nil if invalid_id?(dfn)

      raw = DataMapper.patient_discharge.fetch_scalar(dfn.to_s, fm(admit_datetime))
      return nil if raw.nil? || !raw.include?(".")

      FilemanDateParser.parse_datetime(raw)
    end

    private

    def invalid_id?(id)
      id.nil? || id.to_i <= 0
    end

    # Time/DateTime keep their time of day (seconds preserved when nonzero —
    # ^DGPM movement times are stored to the second and DISCHRG^ORWPT keys on
    # the exact value); Date formats date-only; strings pass through.
    def fm(value)
      FilemanDateParser.to_fileman(value)
    end
  end
end
