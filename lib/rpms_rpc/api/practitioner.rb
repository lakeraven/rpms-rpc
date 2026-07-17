# frozen_string_literal: true

module RpmsRpc
  module Practitioner
    extend self

    # Stock VistA practitioner methods live in VistaRpc. RPMS can extend
    # them here when IHS-specific behavior is needed.
    def find(ien)
      VistaRpc::Practitioner.find(ien)
    end

    def search(name_pattern)
      VistaRpc::Practitioner.search(name_pattern)
    end
  end
end
