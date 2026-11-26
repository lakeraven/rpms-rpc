# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/scheduling_lookups"
require "rpms_rpc/api/agg_lookups"
require "rpms_rpc/api/dg_patient_select"
require_relative "../captured_replies"

# Scheduling's BSDX lookups, Agg's registration lookups and DgPatientSelect,
# on the replies the demo image sent (test/fixtures/captured_replies/
# bsdx-lookups.yml, agg-lookups.yml and dgwpt.yml, recorded as flows),
# replayed through CiaClient's own reads. The round trips are
# test/live/scheduling_lookups_live_test.rb and dg_patient_select_live_test.rb.
class SchedulingLookupsTest < Minitest::Test
  S = RpmsRpc::Scheduling
  A = RpmsRpc::Agg
  D = RpmsRpc::DgPatientSelect
  SLOT = Time.new(2027, 1, 13, 10, 0, 0)

  def teardown
    RpmsRpc.reset!
  end

  def replay(slug, flow)
    @slug = slug
    @flow = flow
    @client = CapturedReplies::ReplayCiaClient.new(CapturedReplies.flow_script(slug, flow))
    RpmsRpc.configure { |cfg| cfg.client = @client }
  end

  def assert_sent(context)
    sent = @client.calls.reject { |c| c[:rpc] == :create_context }
    assert_equal CapturedReplies.flow_calls(@slug, @flow), sent.map { |c| [ c[:rpc], c[:params] ] }, @flow
    return if context == "CIAV VUECENTRIC"

    assert_includes @client.calls, { rpc: :create_context, params: [ context ] }, "#{@flow} binds #{context}"
  end

  def test_the_bsdx_reads
    {
      "schedule_users" => [ -> { S.schedule_users }, [ { id: 4, name: "MANAGER,SYSTEM" } ] ],
      "scheduling_manager" => [ -> { S.scheduling_manager?(duz: "208") }, false ],
      "scheduling_manager_operator" => [ -> { S.scheduling_manager?(duz: 4) }, true ],
      "resource_letters" => [ -> { S.resource_letters([ 1, 2 ]) },
                              [ { id: 1, name: "DEMO PRIMARY CARE", letter: nil, no_show_letter: nil, cancellation_letter: nil },
                                { id: 2, name: "DEMO IHS CLINIC", letter: nil, no_show_letter: nil, cancellation_letter: nil } ] ],
      "no_show_count" => [ -> { S.no_show_count(990_017, 3) },
                           { patient_dfn: 990_017, clinic_ien: 3, too_many: false, allowed: 1, total: 0 } ],
      "patient_lookup" => [ -> { S.patient_lookup("QUEBEC,SAGE") },
                            [ { dfn: 990_017, name: "QUEBEC,SAGE", hrn: "990017", dob: Date.new(2001, 6, 9) } ] ]
    }.each do |flow, (call, expected)|
      replay("bsdx-lookups", flow)
      assert_equal expected, call.call, flow
      assert_sent("BSDXRPC") unless flow.start_with?("scheduling_manager")
    end
  end

  def test_the_resource_groups_and_handouts
    replay("bsdx-lookups", "resource_groups")
    assert_includes S.user_resource_groups(duz: "208"), { id: 1, name: "DEMO IHS CLINIC" }
    replay("bsdx-lookups", "user_resource_group_members")
    assert_includes S.user_resource_group_members(duz: "208").map { |m| m[:resource] }, "DEMO BEHAVIORAL HEALTH"
    replay("bsdx-lookups", "wellness_handout_types")
    assert_equal({ id: 1, name: "ADULT REGULAR" }, S.wellness_handout_types.first)
  end

  def test_the_overlap_reads_send_dt_times_and_parse_the_block
    replay("bsdx-lookups", "access_block_overlaps")
    block = S.access_block_overlaps(resource: "DEMO PRIMARY CARE", start_time: SLOT - 3600, end_time: SLOT).first
    assert_equal Time.new(2027, 1, 13, 8, 0, 0), block[:start_time]
    assert_equal Time.new(2027, 1, 13, 17, 0, 0), block[:end_time]
    assert_equal [ "1/13/2027@09:00", "1/13/2027@10:00", "DEMO PRIMARY CARE" ], CapturedReplies.flow_calls("bsdx-lookups", "access_block_overlaps").first.last

    replay("bsdx-lookups", "appointment_overlaps")
    assert_equal [ { start_time: SLOT, end_time: SLOT + 1200, patient_dfn: 990_020 } ],
                 S.appointment_overlaps(resource: "DEMO PRIMARY CARE", start_time: SLOT, end_time: SLOT + 1200)
  end

  def test_the_booking_reads
    replay("bsdx-lookups", "appointment_events")
    event = S.appointment_events(990_020).find { |e| e[:appt_time] == "Jan 13, 2027 10:00" }
    assert_equal "TANGO,MARLOWE", event[:patient_name]

    replay("bsdx-lookups", "appointment_letter_list")
    letter = S.appointment_letter_list([ 1 ], start_date: SLOT.to_date, end_date: SLOT.to_date).first
    assert_equal "TANGO,MARLOWE", letter[:name]
    assert_equal SLOT, letter[:appointment_time]
    assert_equal "PROFILE,SCHED", letter[:made_by]
    assert_equal [ "1|", "1/13/2027", "1/13/2027", "0" ], CapturedReplies.flow_calls("bsdx-lookups", "appointment_letter_list").first.last

    replay("bsdx-lookups", "cancellation_letter_list")
    cancelled = S.cancellation_letter_list([ 1 ], start_date: SLOT.to_date, end_date: SLOT.to_date).first
    assert_equal SLOT, cancelled[:old_appointment_time]
  end

  def test_the_agg_lookups
    replay("agg-lookups", "version_info")
    version = A.version_info
    assert_equal [ "AG", "7.1", Date.new(2005, 8, 25) ], version.values_at(:package, :version, :version_date)
    assert_sent("AGGRPC")

    { "division_parameters" => [ -> { A.division_parameters }, { complete: true } ],
      "key_held" => [ -> { A.key_held("AGZMENU") }, { held: true } ],
      "key_not_held" => [ -> { A.key_held("AGZMGR") }, { held: false, message: "User does not have key AGZMGR" } ],
      "window_definition_none" => [ -> { A.window_definition("NO SUCH WINDOW") }, [] ] }.each do |flow, (call, expected)|
      replay("agg-lookups", flow)
      assert_equal expected, call.call, flow
      assert_sent("AGGRPC")
    end

    replay("agg-lookups", "reports")
    assert_equal "AGG PATIENT FACE SHEET", A.reports.find { |r| r[:name] == "Face Sheet" }[:rpc]
    replay("agg-lookups", "table_entries")
    assert_includes A.table_entries(9_000_001), { ien: 990_017, name: "QUEBEC,SAGE" }
    replay("agg-lookups", "window_definition")
    assert_equal "AGG ADD NEW PATIENT", A.window_definition("Mini Registration").first[:edit_rpc]
  end

  def test_the_dg_selection_calls
    { "date_of_death" => [ -> { D.date_of_death(990_017) }, nil ],
      "sensitivity" => [ -> { D.sensitivity(990_017) }, 0 ],
      "means_test_required" => [ -> { D.means_test_required?(990_017) }, false ],
      "primary_care" => [ -> { D.primary_care(990_017) }, { team: nil, provider: nil, attending: nil } ],
      "last_selected" => [ -> { D.last_selected }, { dfn: 990_017, name: "QUEBEC,SAGE" } ] }.each do |flow, (call, expected)|
      replay("dgwpt", flow)
      expected.nil? ? assert_nil(call.call, flow) : assert_equal(expected, call.call, flow)
      assert_sent("CIAV VUECENTRIC")
    end

    replay("dgwpt", "clinic_date_ranges")
    assert_equal({ range: "T-7;T", label: "Past Week" }, D.clinic_date_ranges[3])
    replay("dgwpt", "select")
    banner = D.select(990_017)
    assert_equal [ "QUEBEC,SAGE", "F", Date.new(2001, 6, 9), false ], banner.values_at(:name, :sex, :dob, :sensitive)
  end
end
