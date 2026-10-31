# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/patient"

# Chart-banner CWAD must come from ORWPT CWAD under OR CPRS GUI CHART, not
# BEHOCACV CWAD (VueCentric-only). Synthetic seeds only.
class PatientCwadTest < Minitest::Test
  DFN = "42"
  CHART_CONTEXT = "OR CPRS GUI CHART"
  CALLER_CONTEXT = "CIAV VUECENTRIC"
  REQUIRED_RPCS_PATH = File.expand_path("../../../lib/rpms_rpc/required_rpcs.json", __dir__)

  # MockClient subclass: PTINFO/GETBDP still seed; ORWPT CWAD is not served.
  class CwadUnavailableMockClient < RpmsRpc::MockClient
    def seeded_reply(rpc_name, *params)
      if rpc_name == "ORWPT CWAD"
        raise RpmsRpc::Client::RpcNotAvailableError, "3 Unknown remote procedure: ORWPT CWAD"
      end

      super
    end
  end

  def setup
    RpmsRpc.mock!
  end

  def teardown
    RpmsRpc.reset!
  end

  def use(client)
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = client }
  end

  # Proves the registry names the CPRS RPC, not the VueCentric BEHOCACV entry.
  def test_patient_cwad_mapping_uses_orwpt_cwad_rpc
    assert_equal "ORWPT CWAD", RpmsRpc::DataMapper.patient_cwad.rpc_name
  end

  # Proves brief_header asks ORWPT for CWAD with the DFN as its only parameter.
  def test_brief_header_sends_orwpt_cwad_with_dfn_only
    seed_banner(cwad: "WA")
    RpmsRpc::Patient.brief_header(DFN)

    call = cwad_call
    refute_nil call, "expected ORWPT CWAD"
    assert_equal [ DFN ], call[:params]
  end

  # Proves the banner path never calls the VueCentric-only BEHOCACV CWAD RPC.
  def test_brief_header_never_sends_behocacv_cwad
    seed_banner(cwad: "WA")
    RpmsRpc::Patient.brief_header(DFN)

    refute RpmsRpc.client.received_calls.any? { |c| c[:rpc] == "BEHOCACV CWAD" }
  end

  # Proves CWAD runs under OR CPRS GUI CHART and the caller's option is restored.
  def test_brief_header_fetches_cwad_under_or_cprs_gui_chart_and_restores_caller_context
    mock = RpmsRpc.client
    mock.create_context(CALLER_CONTEXT)
    caller_context = mock.current_context
    binds_after_setup = mock.context_binds.length
    seed_banner(cwad: "WA")

    RpmsRpc::Patient.brief_header(DFN)

    refute_nil cwad_call
    assert_equal CHART_CONTEXT, cwad_call[:context]
    assert_equal caller_context, mock.current_context
    assert_equal [ CHART_CONTEXT, caller_context ], mock.context_binds.drop(binds_after_setup)
  end

  # Proves allergy_flag and ad_flag follow A and D in the CWAD scalar.
  def test_brief_header_allergy_and_ad_flags_from_cwad_letters
    {
      "WA" => [ true, false ],
      "CWAD" => [ true, true ],
      "" => [ false, false ]
    }.each do |cwad, (allergy, ad)|
      RpmsRpc.reset!
      RpmsRpc.mock!
      RpmsRpc.client.create_context(CALLER_CONTEXT)
      seed_banner(cwad: cwad)

      header = RpmsRpc::Patient.brief_header(DFN)

      refute_nil header, cwad.inspect
      assert_equal allergy, header[:allergy_flag], "allergy for #{cwad.inspect}"
      assert_equal ad, header[:ad_flag], "ad for #{cwad.inspect}"
    end
  end

  # Proves a broker without ORWPT CWAD fails closed instead of a banner with false flags.
  def test_brief_header_raises_when_orwpt_cwad_is_not_served
    mock = CwadUnavailableMockClient.new
    use(mock)
    mock.create_context(CALLER_CONTEXT)
    caller_context = mock.current_context
    binds_after_setup = mock.context_binds.length
    seed_banner(cwad: "WA")

    assert_raises(RpmsRpc::Client::RpcNotAvailableError) { RpmsRpc::Patient.brief_header(DFN) }

    assert_equal caller_context, mock.current_context
    assert_equal [ CHART_CONTEXT, caller_context ], mock.context_binds.drop(binds_after_setup)
  end

  # Proves required_rpcs.json lists ORWPT CWAD for Patient and drops BEHOCACV CWAD everywhere.
  def test_required_rpcs_lists_orwpt_cwad_under_patient_and_not_behocacv_cwad
    doc = JSON.parse(File.read(REQUIRED_RPCS_PATH))
    patient = doc.fetch("modules").fetch("RpmsRpc::Patient")
    assert_includes patient, "ORWPT CWAD"
    refute_includes doc.fetch("modules").values.flatten, "BEHOCACV CWAD"
  end

  private

  def seed_banner(cwad:)
    mock = RpmsRpc.client
    mock.seed(:patient_ptinfo, DFN,
              { name: "SYNTH,PATIENT", sex: "F", dob_raw: "3010101", mrn: "MRN01", primary_provider: nil })
    mock.seed_scalar(:patient_cwad, DFN, cwad)
  end

  def cwad_call
    RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWPT CWAD" }
  end
end
