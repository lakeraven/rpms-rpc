# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/wait_list"
require "rpms_rpc/api/scheduling"
require "rpms_rpc/api/ddr_fileman"

# A clinic's wait list (rpms-ux S-SCH-10), filed with DDR FILER because no RPC
# files it. The demo build has no list, so the spec makes one the way a
# site's SDZAC holder would, and reads every write back through FileMan.
class WaitListLiveTest < LiveSpec::Test
  writes!

  WL = RpmsRpc::WaitList
  PATIENT = 990_001
  CLINIC = "DEMO IHS CLINIC"

  def setup
    super
    @clinic = RpmsRpc::Scheduling.resources.find { |r| r[:name] == CLINIC }.fetch(:hospital_location_id)
    found = WL.lists.find { |row| row[:clinic_ien] == @clinic }
    @list = found ? found[:ien] : make_list
    set_inactive("0")
    @add_reason = WL.reasons("A").first[:ien]
    @resolution = WL.reasons("R").first[:ien]
  end

  def scoped(&) = RpmsRpc::ContextScope.scoped(RpmsRpc.client, WL::CONTEXT, &)

  def make_list
    filed = scoped { RpmsRpc::DdrFileman.filer(mode: "ADD", rows: [ { file: "9009017.1", field: ".01", iens: "+1,", value: @clinic.to_s } ]) }
    assert filed[:success], filed.inspect
    filed[:iens][1].to_i
  end

  def set_inactive(value)
    filed = scoped { RpmsRpc::DdrFileman.filer(mode: "EDIT", rows: [ { file: "9009017.1", field: ".02", iens: "#{@list},", value: value } ]) }
    assert filed[:success], filed.inspect
  end

  def fields(ien, list)
    reply = scoped { RpmsRpc::DdrFileman.gets_entry(file: "9009017.11", iens: "#{ien},#{@list},", fields: list, flags: "I") }
    reply[:fields].transform_values { |value| value[:internal] }
  end

  def added(**changes)
    result = WL.add(list: @list, patient_dfn: PATIENT, added_on: Date.today, reason: @add_reason, recall_on: Date.today + 30, **changes)
    assert result[:success], result.inspect
    result[:ien]
  end

  def test_s_sch_10_1_a_patient_is_on_the_list_with_the_user_who_added_them
    ien = added(priority: "1")

    filed = fields(ien, ".01;.02;.04;.09")
    assert_equal({ ".01" => PATIENT.to_s, ".02" => "1", ".04" => client.duz.to_s, ".09" => @add_reason.to_s }, filed)
    row = WL.entries(@list).find { |entry| entry[:ien] == ien }
    assert row[:open]
    assert_equal Date.today + 30, row[:recall_on]
    refute_empty row[:patient]
  end

  def test_s_sch_10_2_and_10_3_a_missing_value_or_an_inactive_list_files_nothing
    before = WL.entries(@list).size
    assert_equal :invalid, WL.add(list: @list, patient_dfn: PATIENT, added_on: Date.today, reason: @add_reason, recall_on: nil)[:error]
    assert_equal :invalid, WL.add(list: @list, patient_dfn: PATIENT, added_on: Date.today, reason: @resolution, recall_on: Date.today)[:error]

    set_inactive("1")
    assert_equal "the wait list is inactive",
                 WL.add(list: @list, patient_dfn: PATIENT, added_on: Date.today, reason: @add_reason, recall_on: Date.today)[:message]
    assert_equal before, WL.entries(@list).size
  ensure
    set_inactive("0") if client
  end

  def test_s_sch_10_4_an_edit_leaves_the_entry_open
    ien = added

    assert WL.update(list: @list, entry: ien, priority: "3", recall_on: Date.today + 60)[:success]

    row = WL.entries(@list).find { |entry| entry[:ien] == ien }
    assert_equal "3", row[:priority]
    assert_equal Date.today + 60, row[:recall_on]
    assert row[:open]
  end

  def test_s_sch_10_5_10_6_and_10_8_a_removal_needs_its_date_and_resolution_and_happens_once
    ien = added

    assert_equal :invalid, WL.remove(list: @list, entry: ien, removed_on: nil, resolution: @resolution)[:error]
    assert_equal :invalid, WL.remove(list: @list, entry: ien, removed_on: Date.today, resolution: @add_reason)[:error]
    assert WL.entries(@list).find { |entry| entry[:ien] == ien }[:open]

    assert WL.remove(list: @list, entry: ien, removed_on: Date.today, resolution: @resolution)[:success]
    filed = fields(ien, ".08;.11")
    assert_equal({ ".08" => @resolution.to_s, ".11" => client.duz.to_s }, filed)
    row = WL.entries(@list).find { |entry| entry[:ien] == ien }
    refute row[:open]
    assert_equal Date.today, row[:removed_on]

    assert_equal "the entry is already closed", WL.remove(list: @list, entry: ien, removed_on: Date.today, resolution: @resolution)[:message]
    assert WL.update(list: @list, entry: ien, priority: "2")[:success], "a closed entry can still be edited"
  end
end
