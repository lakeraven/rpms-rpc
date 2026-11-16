# frozen_string_literal: true

require_relative "../shape"
require_relative "../mappings"

module RpmsRpc
  # Symbolic API for imaging studies.
  # Underlying RPC: ORWRA IMAGING EXAMS1.
  #
  # The viewer handoff this module once offered (`launch_token`) sent
  # MAGG IMAGE LAUNCH TOKEN, a name no built 9.0 image registers; it was
  # removed (#207). The registered VistA Imaging surface is MAGG* (MAGGDUZKEY,
  # MAGGPATINFO, MAGGRADLIST, ...); model a handoff from those routines
  # before adding one back (ADR 0003).
  module Image
    extend self
    extend Shape::Declarable

    # The reply's first node is the date range the routine searched,
    # "BEG^END^MAX" (ROOT(-1), which GET^ORWRA sets before any exam row),
    # not an exam, so it is dropped. The exam rows follow it.
    def exams_for_patient(dfn)
      return [] if invalid_id?(dfn)

      mapping = DataMapper.image_exams
      lines = mapping.fetch_text(dfn.to_s).to_s.split(/\r?\n/)
      mapping.parse_many(lines.drop(1))
    end
    shape :exams_for_patient, resource: "images", verb: "GET", path: "/patients/{dfn}/images/exams"

    private

    def invalid_id?(value)
      value.nil? || value.to_s.strip.empty? || value.to_i <= 0
    end
  end
end
