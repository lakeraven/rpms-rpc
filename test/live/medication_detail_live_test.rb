# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/medication"

# Medication.find lists the patient's medications (ORQQPS LIST), then sends
# ORQQPS DETAIL the patient and the medication id, DETAIL(ORY,ORPT,ORMED)^ORQQPS
# (rpms-rpc#678: the id alone left ORMED undefined and the build died in M).
# Both RPCs are in CIAV VUECENTRIC; the spec reads only.
#
# The demo build seeds USER,TEST (DFN 2) an outpatient prescription and a
# pending order (SEEDCHRT); DEMO,PATIENT ONE (DFN 4) has no medication. The
# spec reads the ids and names from DFN 2's own list, so it asserts what the
# build seeds rather than ids written down here. DETAIL reads a prescription by
# its id alone, so find must not answer DFN 2's medication for DFN 4 (#837).
class MedicationDetailLiveTest < LiveSpec::Test
  runs_as :provider
  CONTEXT = "CIAV VUECENTRIC"
  DFN = 2 # USER,TEST, the seed patient
  OTHER_DFN = 4 # DEMO,PATIENT ONE

  def test_find_answers_the_detail_of_each_medication_on_the_patients_list
    listed = seed_medications

    listed.each do |med|
      text = client.with_context(CONTEXT) { RpmsRpc::Medication.find(DFN, med[:id]) }

      refute_nil text, "Medication.find(#{DFN}, #{med[:id].inspect}) answered nil for an id on the patient's list"
      assert_equal med[:name], text.lines.first.to_s.strip.split(/\s{2,}/).first, "detail of #{med.inspect}: #{text.inspect}"
      assert_match(/^\s*Status: \S/, text, "detail of #{med.inspect} names no status")
    end
  end

  def test_find_does_not_answer_another_patients_medication
    listed = seed_medications
    other = client.with_context(CONTEXT) { RpmsRpc::Medication.for_patient(OTHER_DFN) }.map { |row| row[:id] }

    foreign = listed.reject { |med| other.include?(med[:id]) }
    refute_empty foreign, "DFN #{OTHER_DFN} lists every medication DFN #{DFN} does: nothing to prove the guard on"

    foreign.each do |med|
      assert_nil client.with_context(CONTEXT) { RpmsRpc::Medication.find(OTHER_DFN, med[:id]) },
                 "Medication.find(#{OTHER_DFN}, #{med[:id].inspect}) answered DFN #{DFN}'s medication"
    end
  end

  def test_find_sends_nothing_without_a_patient_and_a_list_id
    [ [ nil, "1R;O" ], [ 0, "1R;O" ], [ DFN, "1" ], [ DFN, nil ] ].each do |dfn, id|
      assert_nil RpmsRpc::Medication.find(dfn, id), "Medication.find(#{dfn.inspect}, #{id.inspect})"
    end
  end

  private

  def seed_medications
    listed = client.with_context(CONTEXT) { RpmsRpc::Medication.for_patient(DFN) }
    refute_empty listed, "DFN #{DFN} lists no medication: the demo build seeds it a prescription (SEEDCHRT)"
    listed
  end
end
