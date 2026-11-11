# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc"
require "rpms_rpc/api/phr"
require_relative "../captured_replies"

# Phr.for_patient sends BEHOCIR1 GETCCDS the patient and the date range as
# three parameters, FileMan dates (GETCCDS(DATA,DFN,STRTDT,ENDDT), rpms-rpc#698),
# against the build's own replies (test/fixtures/captured_replies/behocir1-getccds.yml),
# captured as PROFILE,MD for seed patient DFN 4 and replayed through CiaClient.
#
# The build cannot run GETCCDS with any frame: it calls GETIMGS^MAGSIXG1, and
# VistA Imaging's MAGSIXG1 is not in the FOIA release. So these tests prove the
# frame and that the gem raises on that M error; no build has answered a CCD row.
class PhrCcdsTest < Minitest::Test
  SLUG = "behocir1-getccds"

  def teardown
    RpmsRpc.reset!
  end

  def replay(script = {})
    client = CapturedReplies::ReplayCiaClient.new(script)
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def sent(client) = client.calls.map { |c| [ c[:rpc], c[:params] ] }

  def test_for_patient_sends_the_patient_and_the_range_as_three_fileman_parameters_and_raises_the_m_error
    client = replay(CapturedReplies.flow_script(SLUG, "for_patient"))

    error = assert_raises(RpmsRpc::Client::RpcMError) do
      RpmsRpc::Phr.for_patient(4, start_date: Date.new(2000, 1, 1), end_date: Date.new(2026, 12, 31))
    end
    assert_equal CapturedReplies.flow_calls(SLUG, "for_patient"), sent(client)
    assert_equal [ [ "BEHOCIR1 GETCCDS", %w[4 3000101 3261231] ] ], sent(client)
    assert_includes error.message, 'Error while zlinking "MAGSIXG1"'
  end

  def test_for_patient_sends_nothing_for_an_invalid_patient
    client = replay
    [ nil, "", 0, -5, "abc" ].each do |dfn|
      assert_equal [], RpmsRpc::Phr.for_patient(dfn, start_date: Date.new(2025, 5, 26), end_date: Date.new(2026, 5, 26))
    end
    assert_empty client.calls
  end
end
