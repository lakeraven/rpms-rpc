# frozen_string_literal: true

module RpmsRpc
  module BehavioralHealth
    # Write refusal for an AMHG save (rpms-rpc#568).
    #
    # Defined here rather than only in behavioral_health.rb so a cluster
    # loaded on its own still finds the class. behavioral_health.rb reopens
    # this class with the same superclass and documents the visit,
    # purpose-of-visit, progress-note, and PCC cases. Wellness subclasses it.
    class SaveError < RpmsRpc::Error; end
  end
end
