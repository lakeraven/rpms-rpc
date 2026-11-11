# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/eligibility"
require "rpms_rpc/api/encounter"
require "rpms_rpc/api/immunization"
require "rpms_rpc/api/immunization_refusal"
require "rpms_rpc/api/patient_selection"
require "rpms_rpc/api/pov"
require "rpms_rpc/api/procedure"
require "rpms_rpc/api/site"

# The VueCentric-only RPCs bind their own option (ADR 0011, rpms-rpc#528):
# each one's mapping declares CIAV VUECENTRIC, the only broker option the
# build registers it in, so it runs whichever option the session has bound.
#
# The spec signs on (CIA binds CIAV VUECENTRIC), reads with several of the
# APIs that send those RPCs, then binds OR CPRS GUI CHART, which carries none
# of them, and reads again. The broker refuses a kept RPC sent under that
# option (checked first, so the spec can tell a bind from a pass-through).
# Each read answers what it answered under the sign-on option, and the
# session is left on OR CPRS GUI CHART afterwards.
#
# Read only: nothing is filed.
class VuecentricOnlyContextLiveTest < LiveSpec::Test
  OTHER_OPTION = "OR CPRS GUI CHART"
  DFN = 4 # DEMO,PATIENT ONE, the build's seeded patient

  def reads
    duz = client.duz
    {
      "Procedure.for_patient (BGOVCPT GET)" => -> { RpmsRpc::Procedure.for_patient(DFN) },
      "Pov.for_patient (BGOVPOV RECENT)" => -> { RpmsRpc::Pov.for_patient(DFN) },
      "Encounter.visits (BEHOENCX VISITLST)" => -> { RpmsRpc::Encounter.visits(DFN) },
      "Immunization.for_patient (BGOVIMM GET)" => -> { RpmsRpc::Immunization.for_patient(DFN) },
      "Site.current (BEHOSICX SITEINFO)" => -> { RpmsRpc::Site.current(duz) },
      "Eligibility.codes (BGOVIMM2 GETELIG)" => -> { RpmsRpc::Eligibility.codes },
      "ImmunizationRefusal.reasons (BGOREF GETREA)" => -> { RpmsRpc::ImmunizationRefusal.reasons },
      "PatientSelection.find (BEHOPTPL LISTALL)" => -> { RpmsRpc::PatientSelection.find("DEMO") }
    }
  end

  def test_kept_rpcs_answer_the_same_under_another_bound_option
    assert_equal RpmsRpc::CiaClient::SIGNON_CONTEXT, client.current_context
    baseline = reads.transform_values(&:call)
    empty = baseline.select { |_, v| v.nil? || (v.respond_to?(:empty?) && v.empty?) }.keys
    assert_empty empty, "these reads answered nothing under the sign-on option, so they prove no bind: #{empty.join(', ')}"

    client.create_context(OTHER_OPTION)
    assert_raises(RpmsRpc::Client::RpcRefusedError, "#{OTHER_OPTION} is expected to refuse BGOVCPT GET when sent bare") do
      client.call_rpc("BGOVCPT GET", DFN.to_s)
    end

    reads.each do |name, read|
      assert_equal baseline.fetch(name), read.call, "#{name} under #{OTHER_OPTION} differs from its sign-on answer"
      assert_equal OTHER_OPTION, client.current_context, "#{name} left the session off #{OTHER_OPTION}"
    end

    puts "\n#{persona}: #{reads.size} reads of VueCentric-only RPCs answered the same under #{OTHER_OPTION}"
  end
end
