# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/allergy"
require "rpms_rpc/api/encounter"
require "rpms_rpc/api/medication"
require "rpms_rpc/api/problem"
require "rpms_rpc/api/vital"
require "rpms_rpc/fileman_date_parser"

# The Cover Sheet, as the provider reads it (openrpms-ux S-SGN-03.1): for a
# patient with active problems, medications and an allergy, each shows, and
# today's vitals once they are taken. DFN 2 carries all three on the demo
# build (openrpms#1203 seeded its prescriptions). The spec takes a weight
# today on a visit it makes, so it runs on a disposable container only.
class PilotCoverSheetLiveTest < LiveSpec::Test
  runs_as :provider
  proves "S-SGN-03.1"
  writes!

  DFN = 2
  LOCATION_IEN = 6

  def test_the_cover_sheet_shows_problems_medications_the_allergy_and_todays_vitals
    problems = RpmsRpc::Problem.for_patient(DFN).select { |p| p[:status] == "A" }
    refute_empty problems, "DFN #{DFN} has an active problem"
    problems.each { |p| refute_empty p[:description].to_s }

    medications = RpmsRpc::Medication.active_for_patient(DFN)
    assert(medications.any? { |m| m[:status] == "ACTIVE" && !m[:name].to_s.empty? }, medications.inspect)

    allergies = RpmsRpc::Allergy.for_patient(DFN)
    assert(allergies.any? { |a| !a[:allergen].to_s.empty? }, allergies.inspect)

    weight = (150 + rand(40)).to_s
    take_weight_now(weight)
    today = RpmsRpc::Vital.for_patient(DFN).find { |v| v[:type] == "WT" }
    assert_equal weight, today[:value].to_s[/\d+/], "the weight taken now is the one the Cover Sheet shows: #{today.inspect}"
    assert_equal server_now.to_date, today[:recorded_date].to_date
  end

  private

  # The server clock (ORWU DT NOW), so "today" is the server's day.
  def server_now
    RpmsRpc::FilemanDateParser.parse_datetime(Array(client.call_rpc("ORWU DT", "NOW")).first.to_s) ||
      flunk("ORWU DT NOW did not yield a FileMan datetime")
  end

  def take_weight_now(weight)
    at = server_now - 120
    made = RpmsRpc::Encounter.create(DFN, location_ien: LOCATION_IEN, service_category: "A", create: 1,
                                          datetime: RpmsRpc::FilemanDateParser.format_datetime(at))
    flunk "Encounter.create answered #{made.inspect}" unless made[:success]
    vstr = RpmsRpc::Encounter.visit_string(LOCATION_IEN, at, "A", visit_ien: made[:visit_ien])
    saved = RpmsRpc::Vital.add(DFN, vstr, [ { abbreviation: "WT", value: weight, units: "" } ], provider_duz: client.duz, taken_at: at + 60)
    assert saved[:success], saved.inspect
  end
end
