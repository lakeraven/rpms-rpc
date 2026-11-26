# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/immunization_registry"

# The immunization component's reads beside a patient's history (BGOVIMM
# under CIAV VUECENTRIC), as the provider, on the demo image: the stock
# CONTRAINDICATION REASONS, the state forecaster switch (no BGO IMM REGISTRY
# ON parameter turns it off), and a panel patient who is not in the
# immunization registry and has never had a state forecast. Every broker
# role signs on with CIAV VUECENTRIC, so no role is refused these. Reads only.
class ImmunizationRegistryLiveTest < LiveSpec::Test
  runs_as :provider

  I = RpmsRpc::Immunization
  DFN = 990_001 # ALPHA,CASEY
  TETANUS_TOXOID = 104 # IMMUNIZATION (#9999999.14)

  def test_the_stock_contraindication_reasons
    reasons = I.contraindications
    assert_includes reasons, { ien: 4, name: "Anaphylaxis" }
    assert_includes reasons, { ien: 8, name: "Egg Allergy" }
    assert(reasons.all? { |r| r[:ien].positive? && !r[:name].empty? })
  end

  def test_the_forecaster_switch_and_a_patient_it_never_ran_for
    assert I.state_forecaster_on?
    assert_nil I.state_forecast_last_run(DFN)
    assert_nil I.registry_case(DFN), "no panel patient is in the immunization registry"
    refute I.duplicates_allowed?(TETANUS_TOXOID)
  end
end
