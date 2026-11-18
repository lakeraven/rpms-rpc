# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/vital"
require "rpms_rpc/api/encounter"
require "rpms_rpc/api/measurement"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/fileman_date_parser"

# Vital.add files each measurement at the time the caller gives (taken_at),
# not this process's clock: BEHOVM SAVE's VST^DT and VIT+ pieces carry it, and
# V MEASUREMENT (#9000010.01) holds it as the EVENT DATE AND TIME (1201). A
# host whose clock is not the site's (UTC, during a US site's evening) would
# otherwise file the next day.
#
# WRITES against a disposable local container only.
class VitalAddTakenAtLiveTest < LiveSpec::Test
  writes!

  DFN = 2
  LOCATION_IEN = 6

  def test_measurements_are_filed_at_the_time_given
    visit_at = server_now - (rand(30..3000) * 86_400)
    visit_at = visit_at.change(sec: 0) if visit_at.respond_to?(:change)
    made = RpmsRpc::Encounter.create(DFN, location_ien: LOCATION_IEN, service_category: "A", create: 1,
                                          datetime: RpmsRpc::FilemanDateParser.format_datetime(visit_at))
    flunk "Encounter.create answered #{made.inspect}" unless made[:success]
    visit = made[:visit_ien]
    taken = visit_at + 300
    vstr = RpmsRpc::Encounter.visit_string(LOCATION_IEN, visit_at, "A", visit_ien: visit)

    saved = RpmsRpc::Vital.add(DFN, vstr, [ { abbreviation: "WT", value: "169", units: "" } ], provider_duz: client.duz, taken_at: taken)
    assert saved[:success], saved.inspect

    row = Array(RpmsRpc::Measurement.for_visit(visit)).find { |m| m[:type] == "WT" }
    refute_nil row, "no WT on visit #{visit}"
    fields = RpmsRpc::DdrFileman.gets_entry(file: "9000010.01", iens: "#{row[:measurement_ien]},", fields: ".03;1201", flags: "I")[:fields]
    assert_equal visit.to_s, fields.dig(".03", :internal)
    assert_equal RpmsRpc::FilemanDateParser.format_datetime(taken, seconds: true).sub(/0+\z/, "").chomp("."),
                 fields.dig("1201", :internal).to_s, "EVENT DATE AND TIME is the time given"
    puts "\n#{persona}: WT #{row[:measurement_ien]} on visit #{visit} filed at #{fields.dig('1201', :internal)}"
  end

  private

  def server_now
    RpmsRpc::FilemanDateParser.parse_datetime(Array(client.call_rpc("ORWU DT", "NOW")).first.to_s) ||
      flunk("ORWU DT NOW did not yield a FileMan datetime")
  end
end
