# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/scheduling"
require "rpms_rpc/api/scheduling_setup"

# A clinic's hours are its resource's blocks in BSDX ACCESS BLOCK (#9002018.3),
# filed with BSDX ADD NEW AVAILABILITY and removed by date with BSDX CANCEL AV
# BY DATE (rpms-ux S-SCH-14, lakeraven-ehr#806). Read back with BSDX CREATE
# ASGND SLOT SCHED, the read the open-time search uses.
class SchedulingAvailabilityLiveTest < LiveSpec::Test
  writes!

  CLINIC_NAME = "DEMO IHS CLINIC"
  RESOURCE_NAME = "LIVE SPEC AVAILABILITY"

  def test_a_block_is_filed_read_back_and_removed_by_date
    resource = ensure_resource!
    day = far_weekday
    access_type = active_access_type

    added = RpmsRpc::Scheduling.add_availability(
      resource: RESOURCE_NAME, start_time: at(day, 8), end_time: at(day, 12), slots: 2,
      access_type_id: access_type[:id], note: "live spec"
    )
    assert added && added[:success], "BSDX ADD NEW AVAILABILITY failed: #{added.inspect}"

    block = open_blocks(day).find { |b| b[:availability_id] == added[:availability_id] }
    flunk "block #{added[:availability_id]} is not in the slot schedule for #{day}: #{open_blocks(day).inspect}" unless block
    assert_equal [ 8, 12, 2, access_type[:id] ], [ block[:start_time].hour, block[:end_time].hour, block[:slots], block[:access_type_id] ]

    removed = RpmsRpc::Scheduling.cancel_availability_by_date(resource_id: resource[:id], start_date: day, end_date: day)
    assert removed && removed[:success], "BSDX CANCEL AV BY DATE failed: #{removed.inspect}"
    assert_empty open_blocks(day), "#{day} should have no open block on #{RESOURCE_NAME} after the cancel"
  end

  def test_an_unknown_resource_is_refused_and_nothing_is_filed
    day = far_weekday
    reply = RpmsRpc::Scheduling.add_availability(
      resource: "NO SUCH RESOURCE #{rand(10_000)}", start_time: at(day, 8), end_time: at(day, 9), slots: 1,
      access_type_id: active_access_type[:id]
    )

    refute_nil reply, "the broker gave no reply"
    refute reply[:success], "an unknown resource should be refused: #{reply.inspect}"
  end

  private

  # A weekday far past the demo seed's blocks, so the spec owns the day.
  def far_weekday
    day = Date.today + 400 + rand(60)
    day += 1 while day.saturday? || day.sunday?
    day
  end

  def at(day, hour) = Time.new(day.year, day.month, day.day, hour, 0, 0)

  def open_blocks(day)
    RpmsRpc::Scheduling.slot_schedule(resource: RESOURCE_NAME, start_date: day, end_date: day).select { |b| b[:slots].positive? }
  end

  def active_access_type
    @active_access_type ||= RpmsRpc::SchedulingSetup.access_types.find { |t| !t[:inactive] && !t[:prevent_access] } ||
                            flunk("no active BSDX ACCESS TYPE that allows access")
  end

  def ensure_resource!
    existing = RpmsRpc::Scheduling.resources.find { |r| r[:name] == RESOURCE_NAME }
    return existing if existing

    loc = RpmsRpc::Scheduling.hospital_locations.find { |h| h[:location] == CLINIC_NAME }
    flunk "no hospital location named #{CLINIC_NAME}" unless loc

    reply = client.with_context(RpmsRpc::Scheduling::CONTEXT) do
      client.call_rpc("BSDX ADD/EDIT RESOURCE", "0|#{RESOURCE_NAME}|NO|#{loc[:location_ien]}|15")
    end
    flunk "BSDX ADD/EDIT RESOURCE refused #{RESOURCE_NAME}: #{reply.inspect}" if Array(reply).any? { |l| l.match?(/BSDX14:/i) }

    RpmsRpc::Scheduling.resources.find { |r| r[:name] == RESOURCE_NAME } ||
      flunk("BSDX ADD/EDIT RESOURCE answered but #{RESOURCE_NAME} is not in Scheduling.resources")
  end
end
