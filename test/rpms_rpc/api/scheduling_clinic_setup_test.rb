# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"

# A site manager's scheduling setup (lakeraven-ehr#984, #985): a clinic's
# settings, providers and users, the letters it prints, and the access types and
# resource groups Windows Scheduling's table maintenance keeps. Every reply here
# is what a live rpms-ydb 7d0e827 build answered the development operator
# (2026-11-12); the live spec (scheduling_clinic_setup_live_test.rb) proves the
# same calls against a container.
class SchedulingClinicSetupTest < Minitest::Test
  # Answers call_rpc from a list of replies in order, and records each call
  # with the context it was bound under.
  class ReplyClient
    attr_reader :calls

    def initialize(*replies)
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

    def call_rpc(rpc, *params)
      @calls << { rpc: rpc, params: params, context: @context }
      @replies.shift
    end
  end

  def use(*replies)
    client = ReplyClient.new(*replies)
    RpmsRpc.configure { |c| c.client = client }
    client
  end

  def teardown = RpmsRpc.reset!

  CLINIC_6 = [ "[Data]", "44^6^.01^DEMO PRIMARY CARE^DEMO PRIMARY CARE", "44^6^1^DPC^DPC", "44^6^3^7819^DEMO IHS CLINIC",
               "44^6^3.5^3^DEMO IHS CLINIC", "44^6^8^13^INTERNAL MEDICINE", "44^6^1912^20^20", "44^6^1913^V^YES, VARIABLE LENGTH",
               "44^6^1914^8^8", "44^6^1917^3^20-MIN ", "44^6^1918^5^5", "44^6^1918.5^Y^YES", "44^6^2001^3^3", "44^6^2002^120^120",
               "44^6^2500^^", "44^6^2502^N^NO", "44^6^2502.5^^", "44^6^2504^Y^YES", "44^6^2508^^", "44^6^2509^^", "44^6^2510^^",
               "44^6^2511^^" ].freeze
  SETUP_6 = [ "[Data]", "9009017.2^6^.03^^", "9009017.2^6^.09^1^YES", "9009017.2^6^.14^^" ].freeze
  PROVIDERS_6 = [ "[Data]", "1^206^PROFILE,MD^1" ].freeze
  ERRORS_1912 = [ "[Data]", "[BEGIN_diERRORS]", "701^1^44^6,^1912^4", "3^30", "FIELD^1912", "FILE^44", "IENS^6,",
                  "The value '30' for field LENGTH OF APP'T in file HOSPITAL LOCATION is not valid.", "[END_diERRORS]" ].freeze

  def test_clinic_settings_read_the_hospital_location_its_setup_entry_and_providers
    client = use(CLINIC_6, SETUP_6, PROVIDERS_6)

    settings = RpmsRpc::SchedulingSetup.clinic_settings(6)

    assert_equal({ id: 6, name: "DEMO PRIMARY CARE", abbreviation: "DPC", institution: { id: 7819, name: "DEMO IHS CLINIC" },
                   division: { id: 3, name: "DEMO IHS CLINIC" }, stop_code: { id: 13, name: "INTERNAL MEDICINE" },
                   length_minutes: 20, variable_length: true, display_begins: 8, increments_per_hour: 3, overbooks_per_day: 5,
                   schedule_on_holidays: true, allowable_no_shows: 3, max_future_days: 120, prohibit_access: false,
                   non_count: false, include_on_file_room_lists: false, meets_at_facility: true, no_show_letter: nil,
                   pre_appointment_letter: nil, clinic_cancellation_letter: nil, appointment_cancellation_letter: nil,
                   no_show_waiting_days: nil, create_visit_at_checkin: true, visit_provider_required: false, setup_entry: true,
                   providers: [ { id: 1, duz: 206, name: "PROFILE,MD", default: true } ] }, settings)
    assert_equal [ [ "DDR GETS ENTRY DATA", "44" ], [ "DDR GETS ENTRY DATA", "9009017.2" ], [ "DDR LISTER", "44.1" ] ],
                 client.calls.map { |c| [ c[:rpc], c[:params].first["FILE"] ] }
    assert(client.calls.all? { |c| c[:context] == "CIAV VUECENTRIC" })
  end

  def test_a_clinic_with_no_setup_entry_reads_its_setup_fields_as_nil
    clinic = CLINIC_6.map { |l| l.sub("44^6^", "44^11^") }
    use(clinic, [ "[ERROR]" ], [ "[Data]" ])

    settings = RpmsRpc::SchedulingSetup.clinic_settings(11)

    refute settings[:setup_entry]
    assert_nil settings[:create_visit_at_checkin]
    assert_nil settings[:visit_provider_required]
    assert_equal [], settings[:providers]
  end

  def test_each_changed_field_files_on_its_own_with_fileman_validating_it
    client = use([ "[Data]" ], [ "[Data]" ])

    assert_equal({ success: true }, RpmsRpc::SchedulingSetup.update_clinic_settings(6, length_minutes: 40, max_future_days: 90))
    assert_equal [ [ "EDIT", { 1 => "44^1912^6,^40" }, "E", {} ], [ "EDIT", { 1 => "44^2002^6,^90" }, "E", {} ] ],
                 client.calls.map { |c| c[:params] }
  end

  def test_a_refused_field_is_tried_again_after_the_rest_and_named_when_it_still_fails
    client = use(ERRORS_1912, [ "[Data]" ], ERRORS_1912)

    result = RpmsRpc::SchedulingSetup.update_clinic_settings(6, length_minutes: 30, max_future_days: 90)

    assert_equal({ success: false, refused: { length_minutes: "The value '30' for field LENGTH OF APP'T in file HOSPITAL LOCATION is not valid." } },
                 result)
    assert_equal %w[1912 2002 1912], client.calls.map { |c| c[:params][1][1].split("^")[1] }
  end

  def test_flags_pointers_and_clearing_go_as_fileman_external_values
    client = use([ "[Data]" ], [ "[Data]" ], [ "[Data]" ], [ "[Data]" ])

    RpmsRpc::SchedulingSetup.update_clinic_settings(6, variable_length: false, non_count: true, stop_code: 13, max_future_days: nil)

    assert_equal [ "44^1913^6,^@", "44^2502^6,^Y", "44^8^6,^`13", "44^2002^6,^@" ], client.calls.map { |c| c[:params][1][1] }
  end

  def test_setup_fields_add_the_clinics_setup_entry_when_it_has_none
    client = use([ "[ERROR]" ], [ "[Data]", "+1,^11" ])

    result = RpmsRpc::SchedulingSetup.update_clinic_settings(11, create_visit_at_checkin: true, visit_provider_required: true, no_show_waiting_days: 30)

    assert_equal({ success: true }, result)
    assert_equal [ "ADD", { 1 => "9009017.2^.01^+1,^11", 2 => "9009017.2^.09^+1,^1", 3 => "9009017.2^.14^+1,^1",
                            4 => "9009017.2^.03^+1,^30" }, "", { 1 => "11" } ], client.calls.last[:params]
  end

  def test_an_unknown_setting_or_a_bad_value_sends_nothing
    client = use

    assert_raises(ArgumentError) { RpmsRpc::SchedulingSetup.update_clinic_settings(6, name: "RENAMED") }
    assert_raises(ArgumentError) { RpmsRpc::SchedulingSetup.update_clinic_settings(6, length_minutes: "30") }
    assert_raises(ArgumentError) { RpmsRpc::SchedulingSetup.update_clinic_settings(6, variable_length: "Y") }
    assert_raises(ArgumentError) { RpmsRpc::SchedulingSetup.update_clinic_settings(6, abbreviation: "D^C") }
    assert_empty client.calls
  end

  def test_letters_carry_their_type
    use([ "[Data]", "1^APPOINTMENT SLIP^P" ])

    assert_equal [ { id: 1, name: "APPOINTMENT SLIP", type: :pre_appointment } ], RpmsRpc::SchedulingSetup.letters
  end

  def test_access_types_carry_their_colour_when_all_three_parts_are_set
    use([ "[Data]", "5^DEMO BEHAVIORAL HEALTH^0^0^0^128^128", "1^DEMO GENERAL^0^^39^11^244", "6^LUNCH PROBE^0^1^204^51^0", "7^NO COLOUR^0^0^^^" ])

    assert_equal [ [ "DEMO BEHAVIORAL HEALTH", "#008080", false ], [ "DEMO GENERAL", "#270BF4", false ], [ "LUNCH PROBE", "#CC3300", true ],
                   [ "NO COLOUR", nil, false ] ],
                 RpmsRpc::SchedulingSetup.access_types.map { |t| t.values_at(:name, :color, :prevent_access) }
  end

  def test_an_access_type_is_saved_through_bsdx_add_edit_access_type
    client = use([ "I00020ACCESSTYPEID^T00030ERRORTEXT", "6^-1" ],
                 [ "I00020ACCESSTYPEID^T00030ERRORTEXT", "0^BSDX14: Cannot have two Access Types with the same name." ])

    assert_equal({ success: true, id: 6 }, RpmsRpc::SchedulingMaintenance.save_access_type(name: "LUNCH PROBE", prevent_access: true, color: "#CC3300"))
    assert_equal({ success: false, error: "BSDX14: Cannot have two Access Types with the same name." },
                 RpmsRpc::SchedulingMaintenance.save_access_type(name: "LUNCH PROBE"))
    assert_equal [ [ "BSDX ADD/EDIT ACCESS TYPE", [ "0|LUNCH PROBE|NO||204|51|0|YES" ], "BSDXRPC" ],
                   [ "BSDX ADD/EDIT ACCESS TYPE", [ "0|LUNCH PROBE|NO|||||NO" ], "BSDXRPC" ] ],
                 client.calls.map { |c| c.values_at(:rpc, :params, :context) }
  end

  def test_an_access_type_name_or_colour_out_of_range_sends_nothing
    client = use

    [ "LU", "X" * 31, "LUNCH|BREAK", "LUNCH^" ].each do |bad|
      assert_raises(ArgumentError, bad) { RpmsRpc::SchedulingMaintenance.save_access_type(name: bad) }
    end
    assert_raises(ArgumentError) { RpmsRpc::SchedulingMaintenance.save_access_type(name: "LUNCH", color: "red") }
    assert_empty client.calls
  end

  def test_resource_groups_list_every_group_with_its_resources
    use([ "[Data]", "1^DEMO IHS CLINIC^", "2^PROBE GROUP^" ],
        [ "[Data]", "1^1^DEMO PRIMARY CARE", "2^2^DEMO IHS CLINIC" ],
        [ "[Data]", "1^1^DEMO PRIMARY CARE", "2^2^DEMO IHS CLINIC" ])

    groups = RpmsRpc::SchedulingSetup.resource_groups

    assert_equal [ "DEMO IHS CLINIC", "PROBE GROUP" ], groups.map { |g| g[:name] }
    assert_equal [ { id: 2, resource_id: 2, name: "DEMO IHS CLINIC" }, { id: 1, resource_id: 1, name: "DEMO PRIMARY CARE" } ],
                 groups.last[:resources]
  end

  def test_a_group_is_saved_and_its_members_added_and_removed_through_bsdx
    client = use([ "I00020RESOURCEGROUPID^T00030ERRORTEXT", "2^" ],
                 [ "I00020RESOURCEGROUPID^T00030ERRORTEXT", "0^BSDX19: Cannot have two Resource Groups with the same name." ],
                 [ "I00020RESOURCEGROUPITEMID^I00020ERRORID", "1^-1" ],
                 [ "I00020RESOURCEGROUPITEMID^I00020ERRORID", "0^0" ],
                 [ "I00020RESOURCEGROUPITEMID^I00020ERRORID", "9999^70" ],
                 [ "I00020RESOURCEGROUPID^I00020ERRORID", "2^-1" ],
                 [ "I00020RESOURCEGROUPID^I00020ERRORID", "2^70" ])
    s = RpmsRpc::SchedulingMaintenance

    assert_equal({ success: true, id: 2 }, s.save_resource_group(name: "PROBE GROUP"))
    assert_equal({ success: false, error: "BSDX19: Cannot have two Resource Groups with the same name." }, s.save_resource_group(name: "PROBE GROUP"))
    assert_equal({ success: true, id: 1 }, s.add_resource_group_member(group_id: 2, resource_id: 1))
    assert_equal({ success: false, error: :already_in_group }, s.add_resource_group_member(group_id: 2, resource_id: 1))
    assert_equal({ success: false, error: "9999^70" }, s.add_resource_group_member(group_id: 2, resource_id: 9999))
    assert_equal({ success: true }, s.remove_resource_group_member(group_id: 2, item_id: 1))
    assert_equal({ success: false, error: "2^70" }, s.remove_resource_group_member(group_id: 2, item_id: 999))
    assert_equal [ [ "0|PROBE GROUP" ], [ "0|PROBE GROUP" ], %w[2 1], %w[2 1], %w[2 9999], %w[2 1], %w[2 999] ], client.calls.map { |c| c[:params] }
    assert(client.calls.all? { |c| c[:context] == "BSDXRPC" })
  end

  RESOURCES = "9\0I00010RESOURCEID^T00030RESOURCE_NAME^T00010INACTIVE^I00010TIMESCALE^I00010HOSPITAL_LOCATION_ID^T00030LETTER_TEXT^" \
              "T00030NO_SHOW_LETTER^T00030CLINIC_CANCELLATION_LETTER^I00010VIEW^I00010OVERBOOK^I00010MODIFY_SCHEDULE^" \
              "I00010MODIFY_APPOINTMENTS\x1E2^DEMO IHS CLINIC^0^15^3^^^^1^1^1^1\x1E\x1F"
  USERS = [ "[Data]", "2^2^208^PROFILE,SCHED^1^1^1^0", "7^2^206^PROFILE,MD^1^0^1^0" ].freeze

  def test_a_resource_user_is_saved_and_read_back_since_the_built_routine_answers_only_its_header
    client = use(RESOURCES, [ "I00020RESOURCEID^I00020ERRORID" ], USERS)

    assert_equal({ success: true, id: 7 },
                 RpmsRpc::SchedulingMaintenance.save_resource_user(resource_id: 2, duz: 206, overbook: true, modify_appointments: true))
    assert_equal [ "0|YES|NO|2|206|YES" ], client.calls[1][:params]
  end

  def test_a_resource_user_on_a_resource_bsdx_does_not_list_is_refused_before_the_write
    client = use(RESOURCES)

    assert_raises(ArgumentError) { RpmsRpc::SchedulingMaintenance.save_resource_user(resource_id: 9999, duz: 206) }
    assert_equal [ "BSDX RESOURCES" ], client.calls.map { |c| c[:rpc] }
  end

  def test_resource_users_are_the_resources_entries_with_their_rights
    use(USERS)

    assert_equal [ { id: 7, duz: 206, name: "PROFILE,MD", overbook: true, modify_schedule: false, modify_appointments: true, master_overbook: false },
                   { id: 2, duz: 208, name: "PROFILE,SCHED", overbook: true, modify_schedule: true, modify_appointments: true, master_overbook: false } ],
                 RpmsRpc::SchedulingSetup.resource_users(2)
  end

  def test_a_default_provider_clears_the_other_default_first
    client = use([ "[Data]", "1^206^PROFILE,MD^1", "2^4^MANAGER,SYSTEM^0" ], [ "[Data]" ])

    assert_equal({ success: true }, RpmsRpc::SchedulingSetup.set_default_provider(hospital_location_id: 11, entry_id: 2))
    assert_equal [ "EDIT", { 1 => "44.1^.02^1,11,^0", 2 => "44.1^.02^2,11,^1" }, "", {} ], client.calls.last[:params]
  end

  def test_a_provider_the_field_screen_refuses_is_not_added
    client = use([ "[Data]" ], [ "[FILLER]", "[Data]", "^", "", "[BEGIN_diERRORS]", "[END_diERRORS]", "[BEGIN_diHELP]", "44.1^.01^?^5",
                                       "Provider must be active and have an active entry in the NEW PERSON file for PERSON CLASS.", "[END_diHELP]" ])

    result = RpmsRpc::SchedulingSetup.add_clinic_provider(hospital_location_id: 11, duz: 99_999)

    refute result[:success]
    assert_equal [ "DDR LISTER", "DDR VALIDATOR" ], client.calls.map { |c| c[:rpc] }
  end
end
