# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/behavioral_health"
require "rpms_rpc/api/patient"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/fileman_date_parser"

# RpmsRpc::BehavioralHealth.save_visit over AMHG SAVE VISIT (VISIT^AMHGSVF,
# rpms-rpc#536). Files BH VISIT (#9002011) only — not a PCC visit. WRITES
# against a disposable local container only.
class BehavioralHealthSaveVisitLiveTest < LiveSpec::Test
  writes!

  # Synthetic seed patient; not used by other live write specs (see test/live/*write*).
  DFN = 990_033
  BH_VISIT_FILE = "9002011"
  PROGRAM = "MENTAL HEALTH"
  APPOINTMENT_WITH = "WALK-IN"

  CLINIC_FILE = "40.7"
  TYPE_OF_CONTACT_FILE = "9002012.1"
  ENCOUNTER_LOCATION_FILE = "9999999.06"
  COMMUNITY_FILE = "9999999.05"

  def test_save_visit_adds_then_edits_with_readback_through_visit_information
    assert_synthetic_patient!(DFN)
    clinic_ien, type_add, type_edit, location_ien, community_add, community_edit = discover_reference_iens!
    provider = client.duz.to_s
    encounter = server_now_fm

    ien = RpmsRpc::BehavioralHealth.save_visit(
      provider: provider,
      program: PROGRAM,
      clinic: clinic_ien,
      type_of_contact: type_add,
      encounter_date: encounter,
      encounter_location: location_ien,
      community_of_service: community_add,
      appointment_with: APPOINTMENT_WITH,
      patient: DFN,
      esign: false
    )
    refute_empty ien.to_s, "save_visit must return a record IEN"
    assert_match(/\A[1-9]\d*\z/, ien.to_s, "IEN must be a positive integer string")

    info = RpmsRpc::BehavioralHealth.visit_information(ien)
    refute_nil info, "visit_information must return a row for IEN #{ien}"
    assert_equal PROGRAM, info[:program]
    assert_equal clinic_ien.to_s, info.dig(:clinic, :ien).to_s
    assert_equal type_add.to_s, info.dig(:type_of_contact, :ien).to_s
    assert_equal location_ien.to_s, info.dig(:encounter_location, :ien).to_s
    assert_equal community_add.to_s, info.dig(:community_of_service, :ien).to_s
    assert_equal APPOINTMENT_WITH, info[:appointment_with]
    assert_equal provider, info.dig(:primary_provider, :ien).to_s,
                 "primary provider should round-trip (#9002011.02 multiple)"

    filed = RpmsRpc::DdrFileman.gets_entry(
      file: BH_VISIT_FILE, iens: "#{ien},", fields: ".01;.08", flags: "IE"
    )
    refute_nil filed, "DDR GETS on BH visit #{ien}"
    refute filed[:error], filed.inspect
    assert_equal encounter.to_s, filed[:fields].dig(".01", :internal).to_s,
                 "DATE OF SERVICE (.01) must match the FileMan value sent"
    assert_equal DFN.to_s, filed[:fields].dig(".08", :internal).to_s.split(";").first,
                 "PATIENT (.08) on #9002011"

    edited = RpmsRpc::BehavioralHealth.save_visit(
      record_ien: ien,
      provider: provider,
      program: PROGRAM,
      clinic: clinic_ien,
      type_of_contact: type_edit,
      encounter_date: encounter,
      encounter_location: location_ien,
      community_of_service: community_edit,
      appointment_with: APPOINTMENT_WITH,
      patient: DFN,
      esign: false
    )
    assert_equal ien.to_s, edited.to_s, "edit reply must carry the requested IEN (AMHGEVF edit trap)"

    info_after = RpmsRpc::BehavioralHealth.visit_information(ien)
    refute_nil info_after
    assert_equal type_edit.to_s, info_after.dig(:type_of_contact, :ien).to_s,
                 "type of contact should read back as the edited IEN"
    assert_equal community_edit.to_s, info_after.dig(:community_of_service, :ien).to_s,
                 "community of service should read back as the edited IEN"

    puts "\n#{persona}: BH visit #{ien} on DFN #{DFN} added and edited via AMHG SAVE VISIT " \
         "(clinic #{clinic_ien}, types #{type_add}->#{type_edit}, communities #{community_add}->#{community_edit})"
  end

  private

  def discover_reference_iens!
    clinic = first_listed_ien!(CLINIC_FILE, label: "BH clinic")
    types = distinct_listed_iens!(TYPE_OF_CONTACT_FILE, count: 2, label: "type of contact")
    location = first_listed_ien!(ENCOUNTER_LOCATION_FILE, label: "location of encounter")
    communities = distinct_listed_iens!(COMMUNITY_FILE, count: 2, label: "community of service")
    [ clinic, types[0], types[1], location, communities[0], communities[1] ]
  end

  def first_listed_ien!(file, label:)
    listed = list_file(file)
    flunk_no_entries!(file, label, listed) if listed.empty?

    listed.first
  end

  def distinct_listed_iens!(file, count:, label:)
    listed = list_file(file)
    flunk_no_entries!(file, label, listed) if listed.size < count

    listed.first(count)
  end

  def list_file(file)
    listed = RpmsRpc::DdrFileman.lister(file: file, fields: ".01", flags: "IP", max: "25")
    return [] if listed.nil? || listed[:error]

    listed[:entries].map { |row| row[:ien] }.grep(/\A[1-9]\d*\z/)
  end

  def flunk_no_entries!(file, label, listed)
    flunk "no #{label} IEN on file #{file} for this build " \
          "(DDR lister returned #{listed.inspect}); seed reference data or pick another disposable container"
  end

  def assert_synthetic_patient!(dfn)
    row = RpmsRpc::Patient.find(dfn)
    refute_nil row, "DFN #{dfn} must exist on this disposable container seed data"
  end

  def server_now_fm
    value = Array(client.call_rpc("ORWU DT", "NOW")).first.to_s
    RpmsRpc::FilemanDateParser.parse_datetime(value)&.then { |t| RpmsRpc::FilemanDateParser.format_datetime(t) } ||
      flunk("ORWU DT NOW answered #{value.inspect}")
  end
end
