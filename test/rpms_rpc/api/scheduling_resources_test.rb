# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc"

# Scheduling.resources (BSDX RESOURCES) and Scheduling.slot_schedule (BSDX CREATE
# ASGND SLOT SCHED), read as recordsets. The replies are the shapes a live
# rpms-ydb e9b78c8 build answered the scheduler persona (2026-10-27).
class SchedulingResourcesTest < Minitest::Test
  # Answers call_rpc_global_array from a table, and records the context bound.
  class RecordsetClient
    attr_reader :calls

    def initialize(replies)
      @replies = replies
      @calls = []
      @context = "CIAV VUECENTRIC"
    end

    def with_context(name)
      before = @context
      @context = name
      yield
    ensure
      @context = before
    end

    def call_rpc_global_array(rpc, *params)
      @calls << { rpc: rpc, params: params, context: @context }
      @replies.fetch(rpc)
    end
  end

  RESOURCES_HEADER = "I00010RESOURCEID^T00030RESOURCE_NAME^T00010INACTIVE^I00010TIMESCALE^I00010HOSPITAL_LOCATION_ID^" \
                     "T00030LETTER_TEXT^T00030NO_SHOW_LETTER^T00030CLINIC_CANCELLATION_LETTER^I00010VIEW^I00010OVERBOOK^" \
                     "I00010MODIFY_SCHEDULE^I00010MODIFY_APPOINTMENTS"
  SLOTS_HEADER = "D00030START_TIME^D00030END_TIME^I00010SLOTS^T00030RESOURCE^T00010ACCESS_TYPE^T00250NOTE^I00030AVAILABILITYID"

  def use(replies)
    client = RecordsetClient.new(replies)
    RpmsRpc.configure { |c| c.client = client }
    client
  end

  def teardown = RpmsRpc.reset!

  def test_resources_carry_the_clinic_the_slot_length_and_the_users_rights
    use("BSDX RESOURCES" => "1\x00#{RESOURCES_HEADER}\x1e1^DEMO PRIMARY CARE^0^15^6^^^^1^1^1^1\x1e2^DEMO IHS CLINIC^0^15^3^^^^1^0^0^1\x1e\x1f")

    clinic = RpmsRpc::Scheduling.resources.find { |r| r[:name] == "DEMO IHS CLINIC" }

    assert_equal({ id: 2, name: "DEMO IHS CLINIC", inactive: false, time_scale: 15, hospital_location_id: 3,
                   view: true, overbook: false, modify_schedule: false, modify_appointments: true }, clinic)
  end

  # Letter text is word-processing: CR/LF inside a field must not split the row.
  def test_a_letter_with_line_breaks_stays_in_its_row
    use("BSDX RESOURCES" => "1\x00#{RESOURCES_HEADER}\x1e7^LETTER CLINIC^0^20^9^Dear patient,\r\nSee you soon.\r\n^^^1^1^1^1\x1e\x1f")

    assert_equal [ [ 7, "LETTER CLINIC", 20, 9, true ] ],
                 RpmsRpc::Scheduling.resources.map { |r| r.values_at(:id, :name, :time_scale, :hospital_location_id, :modify_appointments) }
  end

  def test_slot_schedule_gives_each_block_its_times_and_slots
    client = use("BSDX CREATE ASGND SLOT SCHED" =>
                   "1\x00#{SLOTS_HEADER}\x1eOCT 28,2026 00:01^OCT 28,2026 08:00^0^DEMO IHS CLINIC^0^^0\x1e" \
                   "OCT 28,2026 08:00^OCT 28,2026 17:00^4^DEMO IHS CLINIC^1^^44\x1e" \
                   "OCT 28,2026 17:00^OCT 28,2026 23:59^0^DEMO IHS CLINIC^0^^0\x1e\x1f")

    blocks = RpmsRpc::Scheduling.slot_schedule(resource: "DEMO IHS CLINIC", start_date: Date.new(2026, 10, 28), end_date: Date.new(2026, 10, 28))

    open = blocks.select { |b| b[:slots].positive? }
    assert_equal 3, blocks.size
    assert_equal [ [ Time.new(2026, 10, 28, 8, 0, 0).hour, 17, 4, 1, 44 ] ],
                 open.map { |b| [ b[:start_time].hour, b[:end_time].hour, b[:slots], b[:access_type_id], b[:availability_id] ] }
    assert_equal [ "DEMO IHS CLINIC", "3261028.0001", "3261028.2359", "", "" ], client.calls.last[:params]
  end

  def test_both_reads_bind_the_bsdxrpc_context
    client = use("BSDX RESOURCES" => "1\x00#{RESOURCES_HEADER}\x1e\x1f",
                 "BSDX CREATE ASGND SLOT SCHED" => "1\x00#{SLOTS_HEADER}\x1e\x1f")

    RpmsRpc::Scheduling.resources
    RpmsRpc::Scheduling.slot_schedule(resource: "X", start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 1, 1))

    assert_equal [ "BSDXRPC", "BSDXRPC" ], client.calls.map { |c| c[:context] }
  end

  def test_no_rows_is_empty_and_no_response_is_nil
    use("BSDX RESOURCES" => "1\x00#{RESOURCES_HEADER}\x1e\x1f")
    assert_equal [], RpmsRpc::Scheduling.resources

    use("BSDX RESOURCES" => nil)
    assert_nil RpmsRpc::Scheduling.resources
  end

  def test_a_resource_name_with_the_list_delimiter_is_refused
    use({})
    assert_raises(ArgumentError) do
      RpmsRpc::Scheduling.slot_schedule(resource: "A|B", start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 1, 1))
    end
  end
end
