# frozen_string_literal: true

module RpmsRpc
  module Allergy
    extend self

    # The allergy read is stock VistA (ORQQAL LIST) and lives in
    # VistaRpc::Allergy. RPMS can extend here when IHS-specific behavior
    # is needed.
    def for_patient(dfn)
      VistaRpc::Allergy.for_patient(dfn)
    end
  end
end
