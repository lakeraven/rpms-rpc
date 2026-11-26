# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/dg_patient_select"

# The ADT patient-selection calls a VueCentric session makes under CIAV
# VUECENTRIC, as the front desk clerk and the scheduler, on the panel patient
# QUEBEC,SAGE (DFN 990017: living, not sensitive, born 06/09/2001, no primary
# care team). Every broker role signs on with CIAV VUECENTRIC, so no role is
# refused these and the spec has no refusal side.
class DgPatientSelectReadsLiveTest < LiveSpec::Test
  runs_as :front_desk_clerk, :scheduler

  D = RpmsRpc::DgPatientSelect
  DFN = 990_017

  def test_a_living_unflagged_panel_patient
    assert_nil D.date_of_death(DFN)
    assert_equal 0, D.sensitivity(DFN)
    refute D.means_test_required?(DFN), "IHS sites keep no VA means test"
    assert_equal({ team: nil, provider: nil, attending: nil }, D.primary_care(DFN))
  end

  def test_the_clinic_list_offers_its_date_ranges
    ranges = D.clinic_date_ranges
    assert_equal({ range: "T;T", label: "Today" }, ranges.first)
    assert_includes ranges, { range: "T-7;T", label: "Past Week" }
  end
end

# DGWPT SELECT records the patient as the user's last selected (^DISV), which
# DGWPT TOP reads back. The spec selects QUEBEC,SAGE, reads it back, and
# selects the user's previous patient again, if there was one.
class DgPatientSelectLiveTest < LiveSpec::Test
  runs_as :front_desk_clerk, :scheduler
  writes!

  D = RpmsRpc::DgPatientSelect
  DFN = 990_017

  def test_selecting_a_patient_answers_the_banner_and_becomes_the_last_selected
    before = D.last_selected
    banner = D.select(DFN)

    assert_equal "QUEBEC,SAGE", banner[:name]
    assert_equal "F", banner[:sex]
    assert_equal Date.new(2001, 6, 9), banner[:dob]
    refute banner[:sensitive]
    assert_nil banner[:admitted]
    assert_operator banner[:age], :>=, 25
    assert_equal({ dfn: DFN, name: "QUEBEC,SAGE" }, D.last_selected)
  ensure
    D.select(before[:dfn]) if before && before[:dfn] != DFN
  end
end
