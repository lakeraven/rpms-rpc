# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/clinical_event"

# The encounter pick lists a nurse chooses from when rooming a patient
# (immunizations, skin tests, health factors by category, exams, education
# topics), read through the ORWPCE GET * RPCs as the nurse (rpms-rpc#347).
# These replace the wire captures of those RPCs. Each list is the release's
# active reference file, so the spec asserts entries the pinned build ships,
# not counts. Reads only.
class EncounterPickListsLiveTest < LiveSpec::Test
  runs_as :nurse

  def clinical_event = RpmsRpc::ClinicalEvent

  def test_immunization_types_list_active_immunizations_by_ien_and_name
    assert_entries clinical_event.immunization_types, including: /\ACOVID-19/
  end

  def test_skin_test_types_list_the_ppd
    names = assert_entries(clinical_event.skin_test_types).map { |t| t[:name] }

    assert_includes names, "PPD"
  end

  def test_exam_types_list_the_screening_exams
    names = assert_entries(clinical_event.exam_types).map { |t| t[:name] }

    assert_includes names, "DEPRESSION SCREENING"
  end

  def test_education_topics_list_coded_topics
    assert_entries clinical_event.education_topics, including: /\ATO-/
  end

  def test_health_factors_name_their_category_only_when_asked
    plain = assert_entries(clinical_event.health_factor_types)
    assert(plain.all? { |h| h[:category].nil? && h[:category_ien].nil? }, "no categories unless asked")

    with = clinical_event.health_factor_types(add_categories: true)
    categories = with.select { |h| h[:category] == "C" }
    assert_includes categories.map { |h| h[:name] }, "ACTIVITY LEVEL"
    factors = with.select { |h| h[:category] == "F" }
    refute_empty factors
    category_iens = categories.map { |h| h[:ien] }
    factors.each do |f|
      assert_includes category_iens, f[:category_ien], "#{f[:name]} names a category the list carries"
    end
  end

  private

  def assert_entries(list, including: nil)
    refute_empty list, "the pinned build ships this reference file: is this the pinned build?"
    list.each do |entry|
      assert_operator entry[:ien], :>, 0, entry.inspect
      refute_empty entry[:name].to_s, entry.inspect
    end
    assert(list.any? { |e| e[:name].match?(including) }, "expected an entry matching #{including.inspect}") if including
    list
  end
end
