# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/phr"

# Phr.for_patient sends BEHOCIR1 GETCCDS the patient and the date range as
# three FileMan-date parameters, GETCCDS(DATA,DFN,STRTDT,ENDDT)^BEHOCIR1
# (rpms-rpc#698). GETCCDS calls GETIMGS^MAGSIXG1, VistA Imaging's, which is
# not in the FOIA release: a build without it answers an M error naming
# MAGSIXG1, and the gem raises it rather than reporting no documents.
# BEHOCIR1 GETCCDS is in CIAV VUECENTRIC; the spec reads only.
class PhrCcdsLiveTest < LiveSpec::Test
  CONTEXT = "CIAV VUECENTRIC"
  DFN = 4 # DEMO,PATIENT ONE on the pinned build

  def test_for_patient_answers_or_raises_the_missing_imaging_routine
    documents = client.with_context(CONTEXT) do
      RpmsRpc::Phr.for_patient(DFN, start_date: Date.new(2000, 1, 1), end_date: Date.new(2026, 12, 31))
    end
    assert_kind_of Array, documents
  rescue RpmsRpc::Client::RpcMError => e
    raise unless e.message.include?('"MAGSIXG1"')

    skip_tracked("#698", "the build has no MAGSIXG1 (VistA Imaging), so GETCCDS cannot answer: #{e.message[/GETCCDS\S+/]}")
  end
end
