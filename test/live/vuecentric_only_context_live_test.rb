# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/eligibility"
require "rpms_rpc/api/encounter"
require "rpms_rpc/api/immunization"
require "rpms_rpc/api/immunization_refusal"
require "rpms_rpc/api/patient_selection"
require "rpms_rpc/api/phr"
require "rpms_rpc/api/ddr_fileman"
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
# The first class reads only. The second files one immunization refusal
# (BGOREF SET, which ImmunizationRefusal.record sends itself), so it runs only
# against a disposable local container, and on a fresh one: a second refusal
# for the same patient, vaccine and day files no new entry (observed on the
# pinned build), as in empty_reply_writes_live_test.rb.
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
      "PatientSelection.find (BEHOPTPL LISTALL)" => -> { RpmsRpc::PatientSelection.find("DEMO") },
      # These two send their RPC themselves, for the raw reply, inside the
      # mapping's in_context.
      "Phr.enrollment_status (BEHOCCD PHR)" => -> { RpmsRpc::Phr.enrollment_status(DFN) },
      "Immunization.text_summary (BGOVIMM PROFILE)" => -> { RpmsRpc::Immunization.text_summary(DFN) }
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

class VuecentricOnlyContextWriteLiveTest < LiveSpec::Test
  writes!

  OTHER_OPTION = VuecentricOnlyContextLiveTest::OTHER_OPTION
  REFUSAL_FILE = "9000022"   # PERSONAL HISTORY REFUSALS (^AUPNPREF)
  REFUSAL_DFN = "990002"     # BRAVO,ALEX, a synthetic seed patient
  TETANUS_TOXOID = "104"     # IMMUNIZATION (#9999999.14)

  def test_a_refusal_is_recorded_under_another_bound_option
    reason = RpmsRpc::ImmunizationRefusal.reasons.first
    refute_nil reason, "the build lists no refusal reasons (GETREA^BGOREF)"
    before = refusal_iens

    client.create_context(OTHER_OPTION)
    result = RpmsRpc::ImmunizationRefusal.record(REFUSAL_DFN, TETANUS_TOXOID, reason_ien: reason[:ien],
                                                 narrative: "live spec")
    assert result[:success], "record under #{OTHER_OPTION} answered #{result.inspect}"
    assert_equal OTHER_OPTION, client.current_context, "record left the session off #{OTHER_OPTION}"

    # The read-back is DDR, which OR CPRS GUI CHART does not carry.
    client.create_context(RpmsRpc::CiaClient::SIGNON_CONTEXT)
    filed = refusal_iens - before
    assert_equal 1, filed.size, "expected one new refusal for DFN #{REFUSAL_DFN}, found #{filed.inspect}"
    puts "\n#{persona}: refusal #{filed.first} recorded under #{OTHER_OPTION} for DFN #{REFUSAL_DFN}"
  end

  private

  def refusal_iens
    listed = RpmsRpc::DdrFileman.lister(file: REFUSAL_FILE, fields: ".02I", flags: "IP", xref: "AC", part: REFUSAL_DFN)
    refute_nil listed, "DDR LISTER on #{REFUSAL_FILE} answered nothing"
    listed[:entries].select { |e| e[:pieces].first == REFUSAL_DFN }.map { |e| e[:ien] }
  end
end
