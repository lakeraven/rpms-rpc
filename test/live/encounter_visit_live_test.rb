# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/encounter"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/fileman_date_parser"

# Visit open/create over BEHOENCX on seed patient DFN 2, visit IEN 1 (#563).
class EncounterVisitLiveTest < LiveSpec::Test
  runs_as "PROV123"
  writes!

  DFN = 2
  VISIT_IEN = 1
  LOCATION_IEN = 6
  VISIT_FILE = "9000010"

  def test_open_visit_one_lists_no_component_the_server_reports_present
    result = RpmsRpc::Encounter.open(DFN, VISIT_IEN)
    refute_nil result, "visit IEN #{VISIT_IEN} must open for DFN #{DFN}"
    assert_equal VISIT_IEN, result[:visit_ien]
    assert_equal DFN, result[:patient_dfn]
    assert_equal LOCATION_IEN, result[:location_ien]

    assert_equal [ { component: "E&M", message: "Visit has no note" } ], result[:missing_components]
  end

  # Every persona: the PCC MASTER CONTROL gap that once refused PROV123's
  # create (TYPE OF VISIT MISSING) is closed on the build, and its create files.
  def test_create_is_get_or_create_and_reads_back
    # A new visit is not a higher IEN: FileMan hands out a free lower one
    # (seen live: 117 after 120). It is one CREATE=0 did not find before.
    datetime = unused_past_visit_datetime_fm
    vstr_args = {
      location_ien: LOCATION_IEN,
      datetime: datetime,
      service_category: "A",
      create: 1
    }
    date_part = datetime.split(".").first

    first = RpmsRpc::Encounter.create(DFN, **vstr_args)
    assert first[:success], "create should succeed: #{first.inspect}"
    visit_ien = first[:visit_ien]
    assert visit_ien.is_a?(Integer) && visit_ien.positive?

    second = RpmsRpc::Encounter.create(DFN, **vstr_args)
    assert second[:success]
    assert_equal visit_ien, second[:visit_ien], "identical CREATE=1 must return the same visit IEN"

    found = RpmsRpc::Encounter.create(DFN, **vstr_args.merge(create: 0))
    assert found[:success]
    assert_equal visit_ien, found[:visit_ien]

    row = RpmsRpc::DataMapper.encounter_visit.fetch_one(visit_ien.to_s)
    refute_nil row
    assert_equal DFN, row[:patient_dfn]
    assert_equal LOCATION_IEN, row[:location_ien]
    assert_equal "A", row[:service_category]
    assert row[:datetime_raw].to_s.start_with?(date_part),
           "GETVISIT datetime_raw #{row[:datetime_raw].inspect} must start with sent date #{date_part.inspect}"
  end

  private

  def server_now_fm
    value = Array(client.call_rpc("ORWU DT", "NOW")).first.to_s
    RpmsRpc::FilemanDateParser.parse_datetime(value)&.then { |t| RpmsRpc::FilemanDateParser.format_datetime(t) } ||
      flunk("ORWU DT NOW did not yield a FileMan datetime")
  end

  VISIT_TIME_TRIES = 10

  # A past visit time at which CREATE=0 finds no visit for DFN, so the create
  # files a new one. A container that already ran the suite holds earlier
  # runs' visits (#810), so a time is drawn until the server finds none there.
  def unused_past_visit_datetime_fm
    base = server_now_fm
    now = RpmsRpc::FilemanDateParser.parse_datetime(base)
    flunk("server now #{base.inspect} did not parse as FileMan datetime") unless now

    tried = Array.new(VISIT_TIME_TRIES) do
      datetime = draw_past_visit_datetime_fm(now)
      found = RpmsRpc::Encounter.create(DFN, location_ien: LOCATION_IEN, datetime: datetime,
                                             service_category: "A", create: 0)
      return datetime unless found && found[:success]

      "#{datetime} (visit #{found[:visit_ien]})"
    end
    flunk "CREATE=0 found a visit for DFN #{DFN} at every time tried: #{tried.join(', ')}"
  end

  def draw_past_visit_datetime_fm(now)
    shifted = now - (rand(30..3000) * 86_400) - (rand(0..59) * 60)
    RpmsRpc::FilemanDateParser.format_datetime(shifted)
  end
end
