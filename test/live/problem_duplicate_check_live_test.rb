# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/patient"
require "rpms_rpc/api/problem"

# Problem.duplicate_check asks BGOPROB2 DUPCHK (DUPCHK^BGOPROB2) whether the
# patient's problem list holds a SNOMED CT concept, the check VueCentric's
# problem entry runs before it adds one; Problem.add files a laterality in
# P-line piece 13 (PROB^BGOPROB3 -> .22). Both in CIAV VUECENTRIC.
#
# The spec checks otitis media (SNOMED CT 65363002, a concept BSTS prompts
# laterality for) on a synthetic patient, adds it on the left, reads .22 and
# the concept back with DDR, finds it on file for the left and not for the
# right, deletes it and finds it gone. A concept BSTS maps to two ICD-10-CM
# codes is filed with both: the build adds the second (SETICD^BGOPROB1).
#
# WRITES against a disposable local container only.
class ProblemDuplicateCheckLiveTest < LiveSpec::Test
  runs_as :provider
  proves "S-VIS-02.2"
  writes!

  DFN = 990_023 # a synthetic seed patient; unused by other live specs
  PROBLEM_FILE = "9000011"
  OTITIS = "65363002"
  NEPHROPATHY = "421986006" # DM 2 w diabetic nephropathy: E11.29 and R80.1

  def test_a_lateralized_problem_is_on_file_for_its_side_and_gone_after_delete
    refute_nil RpmsRpc::Patient.find(DFN), "DFN #{DFN} must exist on this disposable container's seed data"
    location = client.division&.dig(:ien)
    flunk "the session has no division to number the problem under" unless location.to_i.positive?
    clear_concept!(OTITIS)

    check = RpmsRpc::Problem.duplicate_check(DFN, OTITIS, laterality: "Left")
    assert_empty check[:on_file], "DFN #{DFN} already holds #{OTITIS}: #{check.inspect}"
    entry = check[:new_entry]
    refute_nil entry, "BGOPROB2 DUPCHK answered no new entry: #{check.inspect}"
    assert entry[:prompts_laterality], "BSTS prompts laterality for #{OTITIS}"
    refute_empty entry[:icd_codes], "BSTS maps #{OTITIS} to an ICD-10-CM code"

    added = RpmsRpc::Problem.add(DFN, { snomed_ct: OTITIS, descriptive_ct: entry[:description_id], icd_code: entry[:icd_codes].first,
                                        description: entry[:narrative], location_ien: location, laterality: "Left" })
    assert added[:success], "Problem.add answered #{added.inspect}"
    row = fields(added[:ien], ".01;.02;.22;80001;80002")
    assert_equal entry[:icd_codes].first, row.dig(".01", :external)
    assert_equal DFN.to_s, row.dig(".02", :internal)
    assert_equal "272741003|7771000", row.dig(".22", :internal), "the laterality pair is .22 (BGOPROB3.m:170)"
    assert_equal OTITIS, row.dig("80001", :internal)
    assert_equal entry[:description_id], row.dig("80002", :internal)

    left = RpmsRpc::Problem.duplicate_check(DFN, OTITIS, laterality: "Left")
    assert_equal [ added[:ien] ], left[:on_file].map { |e| e[:ien] }, "the left problem is on file for the left"
    right = RpmsRpc::Problem.duplicate_check(DFN, OTITIS, laterality: "Right")
    assert_empty right[:on_file], "the left problem is not on file for the right: #{right.inspect}"

    deleted = RpmsRpc::Problem.delete(DFN, added[:ien], reason: "Entered in error")
    assert deleted[:success], "Problem.delete answered #{deleted.inspect}"
    assert_empty RpmsRpc::Problem.duplicate_check(DFN, OTITIS, laterality: "Left")[:on_file], "a deleted problem is not on file"
    puts "\n#{role}: PROBLEM #{added[:ien]} (#{OTITIS}, left) on DFN #{DFN} found by BGOPROB2 DUPCHK, then deleted"
  end

  def test_a_concept_with_two_icd_maps_is_filed_with_both
    location = client.division&.dig(:ien)
    clear_concept!(NEPHROPATHY)
    entry = RpmsRpc::Problem.duplicate_check(DFN, NEPHROPATHY)[:new_entry]
    assert_operator entry[:icd_codes].size, :>=, 2, "BSTS maps #{NEPHROPATHY} to two codes: #{entry.inspect}"

    added = RpmsRpc::Problem.add(DFN, { snomed_ct: NEPHROPATHY, descriptive_ct: entry[:description_id], icd_code: entry[:icd_codes].first,
                                        description: entry[:narrative], location_ien: location })
    assert added[:success], "Problem.add answered #{added.inspect}"
    filed = RpmsRpc::Problem.integrated_entry(added[:ien])
    assert_equal entry[:icd_codes], [ filed[:icd_code], *filed[:additional_icd].to_s.split(";") ],
                 "the problem carries every code BSTS maps"
  ensure
    RpmsRpc::Problem.delete(DFN, added[:ien], reason: "Entered in error") if added && added[:success]
  end

  private

  def fields(ien, wanted)
    got = RpmsRpc::DdrFileman.gets_entry(file: PROBLEM_FILE, iens: "#{ien},", fields: wanted, flags: "IE")
    flunk "DDR GETS on PROBLEM #{ien} failed: #{got.inspect}" if got.nil? || got[:error]
    got[:fields]
  end

  # A rerun on the same container: problems an earlier run left for the
  # concept are deleted first.
  def clear_concept!(snomed)
    RpmsRpc::Problem.duplicate_check(DFN, snomed)[:on_file].each do |left|
      gone = RpmsRpc::Problem.delete(DFN, left[:ien], reason: "Entered in error")
      flunk "an earlier run's PROBLEM #{left[:ien]} could not be deleted: #{gone.inspect}" unless gone[:success]
    end
  end
end
