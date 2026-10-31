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
  OTHER_DFN = 990_034
  BH_VISIT_FILE = "9002011"
  BH_PROVIDER_FILE = "9002011.02"
  PROGRAM = "MENTAL HEALTH"
  PROGRAM_INTERNAL = "M"
  APPOINTMENT_WITH = "WALK-IN"
  APPOINTMENT_WITH_INTERNAL = "W"

  CLINIC_FILE = "40.7"
  TYPE_OF_CONTACT_FILE = "9002012.1"
  ENCOUNTER_LOCATION_FILE = "9999999.06"
  COMMUNITY_FILE = "9999999.05"

  BH_VISIT_DDR_FIELDS = ".01;.02;.04;.05;.07;.08;.11;.25"
  BH_GROUP_DDR_FIELDS = ".12;.34;1104;1109"
  PROVIDER_LOOKUP_XREF = "AD"
  PROVIDER_LOOKUP_FIELDS = ".01;.02;.03;.04"
  PROVIDER_LOOKUP_FLAGS = "IP"
  PROVIDER_LOOKUP_MAX = "25"

  GROUP_NAME = "SYNTH LIVE GROUP"
  GROUP_TIME = "45"
  ACTIVITY_TIME = "30"

  def test_save_visit_adds_then_edits_with_readback_through_ddr
    assert_synthetic_patient!(DFN)
    clinic_ien, type_add, type_edit, location_ien, community_add, community_edit = discover_reference_iens!
    provider = client.duz.to_s
    encounter = server_now_fm
    edit_common = edit_visit_kwargs(
      provider: provider,
      clinic_ien: clinic_ien,
      type_ien: type_add,
      encounter: encounter,
      location_ien: location_ien,
      community_ien: community_add
    )

    ien = RpmsRpc::BehavioralHealth.save_visit(
      provider: provider,
      program: PROGRAM,
      clinic: clinic_ien,
      type_of_contact: type_add,
      encounter_date: encounter,
      encounter_location: location_ien,
      community_of_service: community_add,
      appointment_with: APPOINTMENT_WITH,
      patient: DFN
    )
    refute_empty ien.to_s, "save_visit must return a record IEN"
    assert_match(/\A[1-9]\d*\z/, ien.to_s, "IEN must be a positive integer string")

    assert_bh_visit_filed_via_ddr!(
      ien,
      encounter: encounter,
      clinic_ien: clinic_ien,
      type_ien: type_add,
      location_ien: location_ien,
      community_ien: community_add,
      patient: DFN
    )
    assert_primary_provider_via_ddr!(ien, provider_duz: provider, patient_dfn: DFN)

    edited = RpmsRpc::BehavioralHealth.save_visit(
      **edit_common.merge(
        record_ien: ien,
        type_of_contact: type_edit,
        community_of_service: community_edit
      )
    )
    assert_equal ien.to_s, edited.to_s, "edit reply must carry the requested IEN (AMHGEVF edit trap)"

    assert_bh_visit_filed_via_ddr!(
      ien,
      encounter: encounter,
      clinic_ien: clinic_ien,
      type_ien: type_edit,
      location_ien: location_ien,
      community_ien: community_edit,
      patient: DFN
    )
    assert_primary_provider_via_ddr!(ien, provider_duz: provider, patient_dfn: DFN)

    date_only_encounter = alternate_encounter_date(encounter)
    date_edited = RpmsRpc::BehavioralHealth.save_visit(
      **edit_common.merge(
        record_ien: ien,
        type_of_contact: type_edit,
        encounter_date: date_only_encounter,
        community_of_service: community_edit
      )
    )
    assert_equal ien.to_s, date_edited.to_s

    assert_bh_visit_filed_via_ddr!(
      ien,
      encounter: date_only_encounter,
      clinic_ien: clinic_ien,
      type_ien: type_edit,
      location_ien: location_ien,
      community_ien: community_edit,
      patient: DFN
    )

    puts "\n#{persona}: BH visit #{ien} on DFN #{DFN} added and edited via AMHG SAVE VISIT " \
         "(clinic #{clinic_ien}, types #{type_add}->#{type_edit}, communities #{community_add}->#{community_edit})"
  end

  def test_save_visit_group_add_edit_blank_group_name_leaves_group_fields
    assert_synthetic_patient!(DFN)
    clinic_ien, type_ien, _type_other, location_ien, community_ien, _community_other = discover_reference_iens!
    provider = client.duz.to_s
    encounter = server_now_fm

    ien = RpmsRpc::BehavioralHealth.save_visit(
      provider: provider,
      program: PROGRAM,
      clinic: clinic_ien,
      type_of_contact: type_ien,
      encounter_date: encounter,
      encounter_location: location_ien,
      community_of_service: community_ien,
      appointment_with: APPOINTMENT_WITH,
      patient: DFN,
      group_name: GROUP_NAME,
      group_time: GROUP_TIME,
      activity_time: ACTIVITY_TIME
    )

    group_snapshot = bh_group_ddr_fields(ien)
    assert_equal ACTIVITY_TIME, group_snapshot.fetch(".12"),
                 "ACTIVITY TIME (.12) after group add"
    assert_equal "1", group_snapshot.fetch(".34"), "GROUP VISIT (.34)"
    assert_equal GROUP_TIME, group_snapshot.fetch("1104"), "TIME SPENT IN GROUP (1104)"
    assert_equal GROUP_NAME, group_snapshot.fetch("1109"), "GROUP NAME (1109)"
    assert_primary_provider_via_ddr!(ien, provider_duz: provider, patient_dfn: DFN)

    RpmsRpc::BehavioralHealth.save_visit(
      **edit_visit_kwargs(
        provider: provider,
        clinic_ien: clinic_ien,
        type_ien: type_ien,
        encounter: encounter,
        location_ien: location_ien,
        community_ien: community_ien,
        record_ien: ien
      )
    )

    after = bh_group_ddr_fields(ien)
    assert_equal group_snapshot, after,
                 "edit with group_name \"\" must leave .12, .34, 1104, and 1109 unchanged"
    assert_primary_provider_via_ddr!(ien, provider_duz: provider, patient_dfn: DFN)
  end

  def test_edit_with_wrong_patient_dfn_refuses_and_leaves_visit_unchanged
    assert_synthetic_patient!(DFN)
    assert_synthetic_patient!(OTHER_DFN)
    clinic_ien, type_ien, _type_other, location_ien, community_ien, _community_other = discover_reference_iens!
    provider = client.duz.to_s
    encounter = server_now_fm

    ien = RpmsRpc::BehavioralHealth.save_visit(
      provider: provider,
      program: PROGRAM,
      clinic: clinic_ien,
      type_of_contact: type_ien,
      encounter_date: encounter,
      encounter_location: location_ien,
      community_of_service: community_ien,
      appointment_with: APPOINTMENT_WITH,
      patient: DFN
    )

    snapshot = bh_visit_ddr_fields(ien)

    err = assert_raises(RpmsRpc::BehavioralHealth::SaveError) do
      RpmsRpc::BehavioralHealth.save_visit(
        **edit_visit_kwargs(
          provider: provider,
          clinic_ien: clinic_ien,
          type_ien: type_ien,
          encounter: encounter,
          location_ien: location_ien,
          community_ien: community_ien,
          record_ien: ien
        ).merge(patient: OTHER_DFN)
      )
    end
    refute_empty err.message

    after = bh_visit_ddr_fields(ien)
    assert_equal snapshot, after, "wrong-patient edit must not change the BH visit row"
  end

  private

  def edit_visit_kwargs(provider:, clinic_ien:, type_ien:, encounter:, location_ien:, community_ien:, record_ien: nil)
    {
      provider: provider,
      program: PROGRAM,
      clinic: clinic_ien,
      type_of_contact: type_ien,
      encounter_date: encounter,
      encounter_location: location_ien,
      community_of_service: community_ien,
      appointment_with: APPOINTMENT_WITH,
      patient: DFN,
      group_name: "",
      group_time: nil,
      activity_time: nil,
      record_ien: record_ien
    }.compact
  end

  def bh_visit_ddr_fields(ien)
    filed = RpmsRpc::DdrFileman.gets_entry(
      file: BH_VISIT_FILE, iens: "#{ien},", fields: BH_VISIT_DDR_FIELDS, flags: "IE"
    )
    flunk "DDR GETS on BH visit #{ien} failed" if filed.nil? || filed[:error]

    filed[:fields].transform_values { |v| v[:internal].to_s }
  end

  def bh_group_ddr_fields(ien)
    filed = RpmsRpc::DdrFileman.gets_entry(
      file: BH_VISIT_FILE, iens: "#{ien},", fields: BH_GROUP_DDR_FIELDS, flags: "IE"
    )
    flunk "DDR GETS on BH visit #{ien} group fields failed" if filed.nil? || filed[:error]

    filed[:fields].transform_values { |v| v[:internal].to_s }
  end

  def alternate_encounter_date(current_fm)
    parsed = RpmsRpc::FilemanDateParser.parse_datetime_or_date(current_fm.to_s)
    flunk("encounter is not a FileMan datetime") unless parsed

    shifted = parsed - (24 * 60 * 60)
    RpmsRpc::FilemanDateParser.format_datetime(shifted) ||
      RpmsRpc::FilemanDateParser.format_date(shifted)
  end

  def assert_bh_visit_filed_via_ddr!(ien, encounter:, clinic_ien:, type_ien:, location_ien:, community_ien:, patient:)
    filed = RpmsRpc::DdrFileman.gets_entry(
      file: BH_VISIT_FILE, iens: "#{ien},", fields: BH_VISIT_DDR_FIELDS, flags: "IE"
    )
    refute_nil filed, "DDR GETS on BH visit #{ien}"
    if filed[:error]
      flunk "DDR GETS on BH visit #{ien} returned an error marker"
    end
    fields = filed[:fields]

    filed_dot01 = fields.dig(".01", :internal).to_s
    sent_dot01 = normalize_filed_encounter(encounter)
    assert_equal sent_dot01, filed_dot01,
                 "DATE OF SERVICE (.01) must match the FileMan value sent (normalized)"

    assert_equal PROGRAM_INTERNAL, fields.dig(".02", :internal).to_s,
                 "PROGRAM (.02) internal code"
    assert_equal location_ien.to_s, fields.dig(".04", :internal).to_s,
                 "LOCATION OF ENCOUNTER (.04)"
    assert_equal community_ien.to_s, fields.dig(".05", :internal).to_s,
                 "COMMUNITY OF SERVICE (.05)"
    assert_equal type_ien.to_s, fields.dig(".07", :internal).to_s,
                 "TYPE OF CONTACT (.07)"
    assert_equal patient.to_s, fields.dig(".08", :internal).to_s.split(";").first,
                 "PATIENT (.08) on #9002011"
    assert_equal APPOINTMENT_WITH_INTERNAL, fields.dig(".11", :internal).to_s,
                 "APPOINTMENT/WALK-IN (.11) internal code"
    assert_equal clinic_ien.to_s, fields.dig(".25", :internal).to_s,
                 "CLINIC (.25)"
  end

  def normalize_filed_encounter(encounter_date)
    text = encounter_date.to_s
    return text unless text.include?(".")

    date, fraction = text.split(".", 2)
    fraction = fraction.sub(/0+\z/, "")
    fraction.empty? ? date : "#{date}.#{fraction}"
  end

  def assert_primary_provider_via_ddr!(visit_ien, provider_duz:, patient_dfn:)
    listed = RpmsRpc::DdrFileman.lister(
      file: BH_PROVIDER_FILE, xref: PROVIDER_LOOKUP_XREF, part: visit_ien.to_s,
      fields: PROVIDER_LOOKUP_FIELDS, flags: PROVIDER_LOOKUP_FLAGS, max: PROVIDER_LOOKUP_MAX
    )
    if listed.nil? || listed[:error]
      flunk "DDR LISTER on #{BH_PROVIDER_FILE} xref #{PROVIDER_LOOKUP_XREF} part #{visit_ien} failed"
    end

    primaries = listed[:entries].select do |entry|
      pieces = entry[:pieces]
      pieces.length >= 4 &&
        pieces[2].to_s == visit_ien.to_s &&
        pieces[3].to_s == "P"
    end

    if primaries.empty?
      flunk "no #{BH_PROVIDER_FILE} row with MHSS RECORD (.03) #{visit_ien} and P/S (.04) P"
    end
    if primaries.size > 1
      flunk "ambiguous primary provider rows on visit #{visit_ien} (#{primaries.size} P rows on AD)"
    end

    pieces = primaries.first[:pieces]
    assert_equal provider_duz.to_s, pieces[0].to_s,
                 "PROVIDER (.01) on #{BH_PROVIDER_FILE} for visit #{visit_ien}"
    assert_equal patient_dfn.to_s, pieces[1].to_s.split(";").first,
                 "PATIENT (.02) on #{BH_PROVIDER_FILE} for visit #{visit_ien}"
  end

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
          "(DDR lister returned #{listed.size} usable rows); seed reference data or pick another disposable container"
  end

  def assert_synthetic_patient!(dfn)
    row = RpmsRpc::Patient.find(dfn)
    refute_nil row, "DFN #{dfn} must exist on this disposable container seed data"
  end

  def server_now_fm
    value = Array(client.call_rpc("ORWU DT", "NOW")).first.to_s
    RpmsRpc::FilemanDateParser.parse_datetime(value)&.then { |t| RpmsRpc::FilemanDateParser.format_datetime(t) } ||
      flunk("ORWU DT NOW did not yield a FileMan datetime")
  end
end
