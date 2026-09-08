# frozen_string_literal: true

require_relative "../fileman_date_parser"
require_relative "../mappings"

module RpmsRpc
  # Symbolic API for recording a patient's refusal of an immunization.
  # Distinct from {RpmsRpc::Immunization}, which is read-only.
  # Underlying RPC: BGOREF SET (SET^BGOREF — BGOREF.m:8), the personal
  # refusals writer (^AUPNPREF #9000022 via $$REFSET2^BGOUTL2 —
  # BGOREF.m:29), called with refusal type "IMMUNIZATION" exactly as the
  # in-package immunization component does (BGOVIMM2.m:100).
  module ImmunizationRefusal
    extend self

    REFUSAL_TYPE = "IMMUNIZATION"

    # Record an immunization refusal.
    #
    # INP layout (BGOREF.m:4-5; parsed :11-20): Refusal IEN[1]^
    # Refusal Type[2]^Item IEN[3]^Patient IEN[4]^Refusal Date[5]^Comment[6]^
    # Provider IEN[7]^Reason[8].
    #
    # vaccine_ien — IMMUNIZATION (#9999999.14) IEN of the refused vaccine
    #   (the item filed at ^AUPNPREF .06 — BGOUTL2.m:105).
    # reason_ien  — REFUSAL REASON (#9999999.102) IEN; the routine reads the
    #   reason's SNOMED concept from that file (BGOREF.m:26-27). Valid IENs
    #   come from {reasons}.
    # refusal_date defaults to today; provider defaults server-side to the
    # signed-on DUZ (BGOUTL2.m:118).
    #
    # REFSET2 returns "" on success (BGOUTL2.m:126-129) — there is no saved
    # IEN in the reply, so :ien is always nil. Errors are -CODE^text
    # (-1050/-1001 bad patient — BGOREF.m:12-13; -1067 bad type —
    # BGOUTL2.m:77).
    def record(dfn, vaccine_ien, reason_ien:, narrative: nil, refusal_date: nil, provider_duz: nil)
      return failure if invalid_id?(dfn) || blank?(vaccine_ien) || blank?(reason_ien)

      inp = [
        "",                 # Refusal IEN — empty for a new refusal
        REFUSAL_TYPE,
        vaccine_ien.to_s,
        dfn.to_s,
        fileman_date(refusal_date || Date.today),
        narrative.to_s,
        provider_duz.to_s,
        reason_ien.to_s
      ].join("^")

      # Client called directly: SET^BGOREF returns "" on success, which
      # fetch_scalar would collapse into nil — indistinguishable from
      # broker silence, and silence must never read as a filed refusal.
      raw = RpmsRpc.client.call_rpc(DataMapper.refusal_set.rpc_name, inp)
      success = raw.is_a?(String) && !raw.match?(/\A-\d+(?:\.\d+)?\^/)
      { success: success, ien: nil, raw: raw }
    end

    # Valid refusal reasons for a refusal type (default "IMMUNIZATION" —
    # BGOREF.m:67). Rows: { ien:, text: } (GETREA^BGOREF — BGOREF.m:61-62).
    def reasons(type = REFUSAL_TYPE)
      Array(DataMapper.refusal_reasons.fetch_many(type.to_s))
    end

    private

    def fileman_date(value)
      case value
      when Date, Time then FilemanDateParser.format_date(value)
      else value.to_s
      end
    end

    def failure
      { success: false, ien: nil, raw: nil }
    end

    def invalid_id?(value)
      value.nil? || value.to_s.strip.empty? || value.to_i <= 0
    end

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end
  end
end
