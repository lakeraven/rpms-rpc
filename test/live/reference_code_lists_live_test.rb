# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/exam_component"
require "rpms_rpc/api/measurement"
require "rpms_rpc/api/taxonomy"

# The RPMS local code lists, read through DDR LISTER as the provider
# (rpms-rpc#917, #918): every measurement type and exam with its code,
# inactive ones flagged; every taxonomy of both files; a code taxonomy's
# ranges and a lab taxonomy's lab tests. Reads only.
class ReferenceCodeListsLiveTest < LiveSpec::Test
  runs_as :provider

  def test_measurement_and_exam_types_carry_codes_and_keep_the_inactive
    [ RpmsRpc::Measurement.types, RpmsRpc::ExamComponent.types ].each do |types|
      refute_empty types
      types.each do |t|
        assert_operator t[:ien], :>, 0
        assert_match(/\A\d+\z/, t[:code], t.inspect)
        refute_empty t[:name], t.inspect
      end
      assert(types.any? { |t| t[:inactive] }, "inactive entries are listed, not dropped")
    end
    assert_includes RpmsRpc::Measurement.types.map { |t| t[:abbreviation] }, "WT"
  end

  def test_every_taxonomy_is_listed_once_with_its_kind_and_member_file
    all = RpmsRpc::Taxonomy.list

    assert_operator all.count { |t| t[:kind] == :code }, :>, 1000
    assert_operator all.count { |t| t[:kind] == :lab }, :>, 100
    assert_equal all.size, all.map { |t| [ t[:kind], t[:ien] ] }.uniq.size, "nothing listed twice across pages"
    assert(all.all? { |t| t[:file].match?(/\A\d+(\.\d+)?\z/) || t[:file].empty? }, "file is a file number")
  end

  def test_a_code_taxonomy_keeps_its_ranges
    taxonomy = RpmsRpc::Taxonomy.members("SURVEILLANCE DIABETES")

    assert_equal [ :code, "80" ], taxonomy.values_at(:kind, :file)
    refute_empty taxonomy[:members]
    taxonomy[:members].each do |m|
      refute_empty m[:low], m.inspect
      refute_empty m[:high], m.inspect
      assert_includes %w[ICD-9-CM ICD-10-CM], m[:code_system]
    end
  end

  def test_a_lab_taxonomy_lists_lab_tests_and_an_unknown_name_is_not_found
    lab = RpmsRpc::Taxonomy.list(prefix: "APCP PAP").find { |t| t[:kind] == :lab }
    flunk "the build has no APCP PAP lab taxonomy" unless lab

    members = RpmsRpc::Taxonomy.members(lab[:name])[:members]
    refute_empty members
    members.each { |m| assert(m[:ien].positive? && !m[:name].empty?, m.inspect) }

    assert_raises(RpmsRpc::Taxonomy::NotFoundError) { RpmsRpc::Taxonomy.members("NO SUCH TAXONOMY") }
  end
end
