# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/behavioral_health"
require "rpms_rpc/api/patient"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/fileman_date_parser"

# RpmsRpc::BehavioralHealth.save_pcc_visit over AMHG CREATE/EDIT VISIT (PCC^AMHGPCC).
# Pinned build: site PCC link off and save_visit does not file .06 activity type, so
# EN^AMHBHRU returns 0~Activity Type Missing! and #9002011 .16 stays blank.
class BehavioralHealthSavePccVisitLiveTest < LiveSpec::Test
  writes!

  DFN = 990_033
  BH_VISIT_FILE = "9002011"
  PROGRAM = "MENTAL HEALTH"
  APPOINTMENT_WITH = "WALK-IN"
  MISSING_RECORD_IEN = "999888777"

  CLINIC_FILE = "40.7"
  TYPE_OF_CONTACT_FILE = "9002012.1"
  ENCOUNTER_LOCATION_FILE = "9999999.06"
  COMMUNITY_FILE = "9999999.05"

  PCC_LINK_FIELD = ".16"

  def test_save_pcc_visit_refuses_activity_type_missing_and_leaves_dot16_blank
    assert_synthetic_patient!(DFN)
    clinic_ien, type_ien, _type_other, location_ien, community_ien, _community_other = discover_reference_iens!
    provider = client.duz.to_s
    encounter = server_now_fm

    record_ien = RpmsRpc::BehavioralHealth.save_visit(
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
    refute_empty record_ien.to_s
    assert_pcc_link_blank!(record_ien)

    err = assert_raises(RpmsRpc::BehavioralHealth::SaveError) do
      RpmsRpc::BehavioralHealth.save_pcc_visit(record_ien: record_ien)
    end
    assert_match(/Activity Type Missing!/i, err.message)
    assert_pcc_link_blank!(record_ien)

    err2 = assert_raises(RpmsRpc::BehavioralHealth::SaveError) do
      RpmsRpc::BehavioralHealth.save_pcc_visit(record_ien: record_ien)
    end
    assert_match(/Activity Type Missing!/i, err2.message)
    assert_pcc_link_blank!(record_ien)

    puts "\n#{persona}: BH visit #{record_ien} on DFN #{DFN} refused PCC link via AMHG CREATE/EDIT VISIT " \
         "(Activity Type Missing!; .16 still blank after two calls)"
  end

  def test_save_pcc_visit_refuses_missing_bh_record_without_writing
    row = RpmsRpc::DdrFileman.gets_entry(
      file: BH_VISIT_FILE, iens: "#{MISSING_RECORD_IEN},", fields: PCC_LINK_FIELD, flags: "I"
    )
    refute_nil row, "DDR GETS on missing IEN #{MISSING_RECORD_IEN} must return a parsed hash, not nil"
    assert row[:error], "missing #9002011 IEN must read as error (gets_entry: empty fields without [Data] or [ERROR])"
    assert_empty row[:fields], "missing entry must not expose field values"

    err = assert_raises(RpmsRpc::BehavioralHealth::SaveError) do
      RpmsRpc::BehavioralHealth.save_pcc_visit(record_ien: MISSING_RECORD_IEN)
    end
    refute_match(/IEN OF MHSS RECORD NOT VALID/i, err.message)
    assert_match(/behavioral health record could not be read/i, err.message)
  end

  private

  def assert_pcc_link_blank!(record_ien)
    filed = RpmsRpc::DdrFileman.gets_entry(
      file: BH_VISIT_FILE, iens: "#{record_ien},", fields: PCC_LINK_FIELD, flags: "IE"
    )
    refute_nil filed, "DDR GETS on BH visit #{record_ien}"
    flunk "DDR GETS on BH visit #{record_ien} returned an error marker" if filed[:error]
    unless filed[:fields].key?(PCC_LINK_FIELD)
      flunk "DDR GETS on BH visit #{record_ien} did not return the #{PCC_LINK_FIELD} field"
    end

    dot16 = filed.dig(:fields, PCC_LINK_FIELD, :internal).to_s.strip
    assert_empty dot16, "PCC VISIT LINK (.16) must stay blank on this pinned build"
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
