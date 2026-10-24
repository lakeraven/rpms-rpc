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

    def exams_for_patient(dfn)
      return [] if invalid_id?(dfn)

      Array(DataMapper.image_exams.fetch_many(dfn.to_s))
    end
    shape :exams_for_patient, resource: "images", verb: "GET", path: "/patients/{dfn}/images/exams"

    private

    def invalid_id?(value)
      value.nil? || value.to_s.strip.empty? || value.to_i <= 0
    end
  end
end
