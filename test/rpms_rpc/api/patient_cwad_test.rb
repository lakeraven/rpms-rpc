# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "rpms_rpc"
require "rpms_rpc/retry_safety"
require "rpms_rpc/api/patient"
require "rpms_rpc/shape"
require_relative "../captured_replies"

# Chart-banner CWAD must come from ORWPT CWAD, not BEHOCACV CWAD (VueCentric-only),
# on the caller's option: CIAV VUECENTRIC lists it, and binding OR CPRS GUI CHART
# is refused on IRIS to a user without it.
#
# Replies are the pinned build's: the banner reads for seed patient DFN 4
# (patient-brief-header.yml) and ORWPT CWAD for seed patients with and
# without postings, plus the broker's refusal of an RPC it does not serve
# (orwpt-cwad-letters.yml), replayed through CiaClient. The guard test keeps a
# captured frame and changes only its body; it says so.
class PatientCwadTest < Minitest::Test
  DFN = "4"
  CALLER_CONTEXT = "CIAV VUECENTRIC"
  CWAD = "orwpt-cwad-letters"
  REQUIRED_RPCS_PATH = File.expand_path("../../../lib/rpms_rpc/required_rpcs.json", __dir__)
  WRITE_CLASS_GET_BASELINE = File.expand_path("../../../data/openapi/write_class_get_baseline.txt", __dir__)

  def teardown
    RpmsRpc.reset!
  end

  # DFN 4's banner reads, with ORWPT CWAD answering the given raw reply.
  def replay_banner(cwad_raw = CapturedReplies.raw(CWAD, "warning_and_allergy"))
    banner = "patient-brief-header"
    @client = CapturedReplies::ReplayCiaClient.new(
      "BEHOPTCX PTINFO" => [ CapturedReplies.raw(banner, "ptinfo") ],
      "BEHOPTPC GETBDP" => [ CapturedReplies.raw(banner, "getbdp") ],
      "ORWPT CWAD" => [ cwad_raw ]
    )
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = @client }
    @client
  end

  def cwad_call = @client.calls.find { |c| c[:rpc] == "ORWPT CWAD" }

  # Proves the registry names the CPRS RPC, not the VueCentric BEHOCACV entry.
  def test_patient_cwad_mapping_uses_orwpt_cwad_rpc
    assert_equal "ORWPT CWAD", RpmsRpc::DataMapper.patient_cwad.rpc_name
  end

  # Proves brief_header asks ORWPT for CWAD with the DFN as its only parameter.
  def test_brief_header_sends_orwpt_cwad_with_dfn_only
    replay_banner
    RpmsRpc::Patient.brief_header(DFN)

    refute_nil cwad_call, "expected ORWPT CWAD"
    assert_equal [ DFN ], cwad_call[:params]
  end

  # Proves the banner path never calls the VueCentric-only BEHOCACV CWAD RPC.
  def test_brief_header_never_sends_behocacv_cwad
    replay_banner
    RpmsRpc::Patient.brief_header(DFN)

    assert_equal [ "BEHOPTCX PTINFO", "BEHOPTPC GETBDP", "ORWPT CWAD" ], @client.rpcs_called
  end

  # Proves CWAD runs on the caller's option and no option is bound for it.
  def test_brief_header_fetches_cwad_on_the_callers_option_and_binds_none
    replay_banner
    RpmsRpc::Patient.brief_header(DFN)

    assert_equal CALLER_CONTEXT, @client.current_context
    refute @client.rpcs_called.include?(:create_context)
  end

  # Proves allergy_flag and ad_flag follow A and D in the CWAD letters RPMS sent.
  def test_brief_header_allergy_and_ad_flags_from_captured_cwad_letters
    {
      "warning_and_allergy" => [ true, false ],
      "allergy" => [ true, false ],
      "none" => [ false, false ]
    }.each do |capture, (allergy, ad)|
      replay_banner(CapturedReplies.raw(CWAD, capture))

      header = RpmsRpc::Patient.brief_header(DFN)

      refute_nil header, capture
      assert_equal allergy, header[:allergy_flag], "allergy for #{capture}"
      assert_equal ad, header[:ad_flag], "ad for #{capture}"
    end
  end

  # Proves a reply that is not CWAD letters raises instead of reading flags from
  # a substring, and does not echo the reply. The frame is the captured one
  # (DFN 4's sequence echo); only its body is replaced.
  def test_brief_header_raises_on_a_cwad_reply_that_is_not_letters_without_echoing_it
    frame = CapturedReplies.raw(CWAD, "warning_and_allergy")
    [ "-1^Invalid DFN", "Application context denied", "DATA", "ad" ].each do |body|
      replay_banner(frame.byteslice(0, 2) + body.b)

      err = assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Patient.brief_header(DFN) }
      assert_match(/ORWPT CWAD/i, err.message, "message must name the RPC for #{body.inspect}")
      refute_includes err.message, body, "ORWPT CWAD error must not echo raw reply text for #{body.inspect}"
    end
  end

  # Proves a broker that does not serve ORWPT CWAD fails closed instead of a
  # banner with false flags. The refusal is the build's for an unregistered
  # name (ORWPT CWADX); it is the reply a build without ORWPT CWAD sends.
  def test_brief_header_raises_when_orwpt_cwad_is_not_served
    replay_banner(CapturedReplies.raw(CWAD, "unknown_rpc"))

    assert_raises(RpmsRpc::Client::RpcNotAvailableError) { RpmsRpc::Patient.brief_header(DFN) }
    assert_equal CALLER_CONTEXT, @client.current_context
    refute @client.rpcs_called.include?(:create_context)
  end

  # Classed non_idempotent_write since #520, when it bound OR CPRS GUI CHART for CWAD.
  # It binds nothing now; the class and its POST shape stay until the catalog is
  # changed on purpose, so a host is told no less than before.
  def test_brief_header_is_non_idempotent_write_in_retry_safety
    assert_equal :non_idempotent_write, RpmsRpc::RetrySafety.for(RpmsRpc::Patient, :brief_header)
    refute RpmsRpc::RetrySafety.auto_retry_safe?(RpmsRpc::Patient, :brief_header)
  end

  # Context-binding write (like Patient.contact): POST at a stable sub-path, not a baseline GET exception (#520).
  def test_brief_header_declared_shape_is_post_and_not_in_write_class_get_baseline
    shape = RpmsRpc::Shape.for(RpmsRpc::Patient, :brief_header)

    refute_nil shape
    assert_equal "POST", shape[:verb]
    assert_equal "/patients/{dfn}/brief-header", shape[:path]

    baseline = File.readlines(WRITE_CLASS_GET_BASELINE, chomp: true).reject(&:empty?)
    refute_includes baseline, "RpmsRpc::Patient.brief_header"
  end

  # Proves required_rpcs.json lists ORWPT CWAD for Patient and drops BEHOCACV CWAD everywhere.
  def test_required_rpcs_lists_orwpt_cwad_under_patient_and_not_behocacv_cwad
    doc = JSON.parse(File.read(REQUIRED_RPCS_PATH))
    patient = doc.fetch("modules").fetch("RpmsRpc::Patient")
    assert_includes patient, "ORWPT CWAD"
    refute_includes doc.fetch("modules").values.flatten, "BEHOCACV CWAD"
  end
end
