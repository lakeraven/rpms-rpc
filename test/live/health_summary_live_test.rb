# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/health_summary"

# HealthSummary.summary_types reads the IHS summary types the site lists
# (ORWRP REPORT LISTS), and for_patient prints one through the IHS report
# (ORWRP REPORT TEXT, RPTID "IHS", HS^ORWRPBHS) for that type's IEN. Before
# #662 the gem sent report 1 with an invented type IEN, which the build ran
# as a VA type and faulted on. The spec reads only.
class HealthSummaryLiveTest < LiveSpec::Test
  DFN = 4 # DEMO,PATIENT ONE

  def test_the_site_lists_ihs_summary_types_with_their_iens
    types = RpmsRpc::HealthSummary.summary_types

    refute_nil types, "ORWRP REPORT LISTS listed no health summary types"
    refute_empty types
    assert(types.all? { |t| t[:ien].match?(/\A\d+\z/) && !t[:name].empty? }, types.inspect)
    puts "\n#{persona}: #{types.size} IHS summary types, first #{types.first.inspect}"
  end

  def test_for_patient_prints_the_default_summary_with_its_sections
    summary = RpmsRpc::HealthSummary.for_patient(DFN)

    assert_nil summary[:error], summary[:error]
    assert_equal RpmsRpc::HealthSummary::DEFAULT_SUMMARY_TYPE, summary[:type]
    assert_includes summary[:raw_content], "(#{summary[:type]} SUMMARY)", "the report names the type it printed"
    refute_empty summary[:sections]
    puts "\n#{persona}: #{summary[:sections].map { |s| s[:name] }.first(4).inspect}"
  end

  def test_every_listed_type_prints_without_a_fault
    RpmsRpc::HealthSummary.summary_types.each do |type|
      summary = RpmsRpc::HealthSummary.for_patient(DFN, summary_type: type[:ien])

      assert_nil summary[:error], "#{type[:name]} (#{type[:ien]}): #{summary[:error]}"
      assert_includes summary[:raw_content], "(#{type[:name]} SUMMARY)"
    end
  end

  def test_a_type_the_site_does_not_list_sends_no_report
    summary = RpmsRpc::HealthSummary.for_patient(DFN, summary_type: "LIVESPEC NO SUCH TYPE")

    assert_equal "Unknown health summary type: LIVESPEC NO SUCH TYPE", summary[:error]
  end
end
