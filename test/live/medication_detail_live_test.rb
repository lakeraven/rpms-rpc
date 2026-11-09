# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/medication"

# Medication.find sends ORQQPS DETAIL the patient and the medication id,
# DETAIL(ORY,ORPT,ORMED)^ORQQPS (rpms-rpc#678). The id alone left ORMED
# undefined and the build died in M. ORQQPS DETAIL is in CIAV VUECENTRIC;
# the spec reads only.
#
# No demo patient on the pinned build has a medication, so the ids are ones
# the patient does not have, and the build answers DETAIL's own "not found"
# text. That proves the frame, not the detail lines of a real medication.
class MedicationDetailLiveTest < LiveSpec::Test
  CONTEXT = "CIAV VUECENTRIC"
  DFN = 4 # DEMO,PATIENT ONE on the pinned build

  def test_find_reaches_detail_with_the_patient_and_the_id
    [ "1R;O", "1U;I" ].each do |id|
      text = client.with_context(CONTEXT) { RpmsRpc::Medication.find(DFN, id) }

      assert_equal "No detailed information found.", text.to_s.strip, "Medication.find(#{DFN}, #{id.inspect})"
    end
  end

  def test_find_sends_nothing_without_a_patient_and_a_list_id
    [ [ nil, "1R;O" ], [ 0, "1R;O" ], [ DFN, "1" ], [ DFN, nil ] ].each do |dfn, id|
      assert_nil RpmsRpc::Medication.find(dfn, id), "Medication.find(#{dfn.inspect}, #{id.inspect})"
    end
  end
end
