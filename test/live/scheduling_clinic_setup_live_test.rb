# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/scheduling"
require "rpms_rpc/api/scheduling_setup"
require "rpms_rpc/api/scheduling_maintenance"

# A site manager's scheduling setup on a real build (lakeraven-ehr#984, #985):
# a clinic's settings filed and read back from HOSPITAL LOCATION (#44) and
# CLINIC SETUP PARAMETERS (#9009017.2), its providers and users, and the
# access types and resource groups of Windows Scheduling's table maintenance.
# Each test puts back what it changed, or adds names of its own.
class SchedulingClinicSetupLiveTest < LiveSpec::Test
  writes!

  CLINIC = "DEMO PODIATRY"

  def setup_api = RpmsRpc::SchedulingSetup
  def bsdx = RpmsRpc::Scheduling
  def maint = RpmsRpc::SchedulingMaintenance

  def clinic
    @clinic ||= bsdx.resources.find { |r| r[:name] == CLINIC } || flunk("the build has no #{CLINIC} resource")
  end

  def test_a_clinics_settings_are_filed_and_read_back_from_its_hospital_location
    ien = clinic[:hospital_location_id]
    before = setup_api.clinic_settings(ien)
    assert_equal CLINIC, before[:name]
    length = before[:length_minutes] == 60 ? 30 : 60

    begin
      result = setup_api.update_clinic_settings(ien, length_minutes: length, max_future_days: 45, allowable_no_shows: 999)
      assert_equal({ success: true }, result)
      after = setup_api.clinic_settings(ien)
      assert_equal [ length, 45, 999 ], after.values_at(:length_minutes, :max_future_days, :allowable_no_shows)
      assert_equal 45, setup_api.clinic_rules(ien)[:max_future_days], "the booking rules read the same field"
    ensure
      setup_api.update_clinic_settings(ien, before.slice(:length_minutes, :max_future_days, :allowable_no_shows))
    end
    assert_equal before.except(:providers), setup_api.clinic_settings(ien).except(:providers)
  end

  def test_fileman_refuses_what_the_clinics_own_editor_would_and_files_the_rest
    ien = clinic[:hospital_location_id]
    before = setup_api.clinic_settings(ien)

    begin
      result = setup_api.update_clinic_settings(ien, length_minutes: 25, allowable_no_shows: 1000, max_future_days: 30)
      refute result[:success]
      assert_equal %i[allowable_no_shows length_minutes], result[:refused].keys.sort
      assert_match(/LENGTH OF APP'T/, result[:refused][:length_minutes])
      assert_equal 30, setup_api.clinic_settings(ien)[:max_future_days], "the valid field is filed"
    ensure
      setup_api.update_clinic_settings(ien, before.slice(:max_future_days))
    end
  end

  def test_a_letter_of_the_wrong_type_is_refused_by_the_fields_screen
    ien = clinic[:hospital_location_id]
    pre = setup_api.letters.find { |l| l[:type] == :pre_appointment } || flunk("the build has no pre-appointment LETTER (#407.5)")

    result = setup_api.update_clinic_settings(ien, no_show_letter: pre[:id])
    refute result[:success]
    assert_includes result[:refused].keys, :no_show_letter
  end

  def test_create_visit_at_checkin_files_on_the_clinic_setup_parameters
    ien = clinic[:hospital_location_id]
    before = setup_api.clinic_settings(ien)

    begin
      assert_equal({ success: true }, setup_api.update_clinic_settings(ien, create_visit_at_checkin: true, visit_provider_required: true))
      after = setup_api.clinic_settings(ien)
      assert after[:setup_entry]
      assert after[:create_visit_at_checkin]
      assert after[:visit_provider_required]
      assert setup_api.creates_visit_at_checkin(ien), "check-in reads the same field"
    ensure
      if before[:setup_entry]
        setup_api.update_clinic_settings(ien, before.slice(:create_visit_at_checkin, :visit_provider_required))
      end
    end
  end

  def test_a_provider_is_added_made_default_and_removed
    ien = clinic[:hospital_location_id]
    duz = client.duz.to_i
    before = setup_api.clinic_providers(ien)
    added = setup_api.add_clinic_provider(hospital_location_id: ien, duz: duz, default: true)
    assert added[:success], added.inspect

    providers = setup_api.clinic_providers(ien)
    assert_equal [ duz ], providers.select { |p| p[:default] }.map { |p| p[:duz] }
  ensure
    setup_api.remove_clinic_provider(hospital_location_id: ien, entry_id: added[:id]) if added&.dig(:success) && before.none? { |p| p[:duz] == duz }
  end

  def test_an_access_type_that_prevents_access_is_saved_with_its_colour
    name = "LIVE LUNCH #{Time.now.strftime('%H%M%S')}"
    saved = maint.save_access_type(name: name, prevent_access: true, color: "#CC3300")
    assert saved[:success], saved.inspect

    type = setup_api.access_types.find { |t| t[:id] == saved[:id] }
    assert_equal [ name, true, false, "#CC3300" ], type.values_at(:name, :prevent_access, :inactive, :color)
    refute maint.save_access_type(name: name)[:success], "a second access type of the same name is refused"

    assert maint.save_access_type(id: saved[:id], name: name, inactive: true, prevent_access: true)[:success]
    assert setup_api.access_types.find { |t| t[:id] == saved[:id] }[:inactive]
  end

  def test_a_resource_group_of_two_clinics_is_built_and_read_back
    name = "LIVE GROUP #{Time.now.strftime('%H%M%S')}"
    group = maint.save_resource_group(name: name)
    assert group[:success], group.inspect
    two = bsdx.resources.reject { |r| r[:inactive] }.first(2)
    two.each { |r| assert maint.add_resource_group_member(group_id: group[:id], resource_id: r[:id])[:success] }

    read = setup_api.resource_groups.find { |g| g[:id] == group[:id] }
    assert_equal two.map { |r| r[:id] }.sort, read[:resources].map { |m| m[:resource_id] }.sort
    assert_equal :already_in_group, maint.add_resource_group_member(group_id: group[:id], resource_id: two.first[:id])[:error]

    assert maint.remove_resource_group_member(group_id: group[:id], item_id: read[:resources].first[:id])[:success]
    assert_equal 1, setup_api.resource_groups.find { |g| g[:id] == group[:id] }[:resources].size
  end

  def test_a_clinic_user_is_given_rights_and_taken_off
    duz = client.duz.to_i
    before = setup_api.resource_users(clinic[:id]).find { |u| u[:duz] == duz }
    saved = maint.save_resource_user(resource_id: clinic[:id], duz: duz, overbook: true, modify_appointments: true)
    assert saved[:success], saved.inspect
    assert setup_api.set_master_overbook(resource_user_id: saved[:id], master: true)[:success]

    user = setup_api.resource_users(clinic[:id]).find { |u| u[:id] == saved[:id] }
    assert_equal [ true, false, true, true ], user.values_at(:overbook, :modify_schedule, :modify_appointments, :master_overbook)
  ensure
    if saved&.dig(:success)
      if before
        maint.save_resource_user(resource_id: clinic[:id], duz: duz, **before.slice(:overbook, :modify_schedule, :modify_appointments))
        setup_api.set_master_overbook(resource_user_id: saved[:id], master: before[:master_overbook])
      else
        maint.remove_resource_user(saved[:id])
      end
    end
  end
end
