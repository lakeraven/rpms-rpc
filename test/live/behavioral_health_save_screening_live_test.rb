# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/behavioral_health"
require "rpms_rpc/api/patient"
require "rpms_rpc/api/ddr_fileman"

# RpmsRpc::BehavioralHealth.save_screening over AMHG SAVE SCREENING (SCREEN^AMHGSVF).
# WRITES on a disposable container only; synthetic patient DFN 990036.
class BehavioralHealthSaveScreeningLiveTest < LiveSpec::Test
  writes!

  DFN = 990_036
  PROGRAM = "MENTAL HEALTH"
  APPOINTMENT_WITH = "WALK-IN"

  CLINIC_FILE = "40.7"
  TYPE_OF_CONTACT_FILE = "9002012.1"
  ENCOUNTER_LOCATION_FILE = "9999999.06"
  COMMUNITY_FILE = "9999999.05"

  def test_save_screening_files_alcohol_and_suicide_risk_then_read_via_amhg_get_visit_screening
    assert_synthetic_patient!(DFN)
    clinic_ien, type_ien, _t2, location_ien, community_ien, _c2 = discover_reference_iens!
    provider = client.duz.to_s
    encounter = server_now_fm

    visit_ien = RpmsRpc::BehavioralHealth.save_visit(
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

    RpmsRpc::BehavioralHealth.save_screening(
      record_ien: visit_ien,
      patient: DFN,
      alcohol_result: "POSITIVE",
      alcohol_comment: "SYN LIVE ALC",
      depression_result: "",
      depression_comment: "",
      ipv_result: "",
      ipv_comment: "",
      wellness_primary_provider: "",
      alcohol_screening_provider: provider,
      depression_screening_provider: "",
      ipv_screening_provider: "",
      suicide_result: "NEGATIVE",
      suicide_comment: "SYN LIVE SUI",
      suicide_screening_provider: provider,
      suicide_screening_result: "",
      suicide_screening_comment: "",
      suicide_screening_ipv_provider: ""
    )

    rows = RpmsRpc::BehavioralHealth.visit_screenings(visit_ien)
    refute_empty rows, "expected at least one screening row after save"
    suicide = rows.find { |r| r[:screening_type] == "Suicide Risk" }
    refute_nil suicide, "Suicide Risk screening must round-trip via AMHG GET VISIT SCREENING"
    assert_equal "NEGATIVE", suicide[:result]

    puts "\n#{persona}: BH visit #{visit_ien} screening saved on DFN #{DFN}"
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
    flunk "no #{label} IEN on file #{file} for this build (lister returned #{listed.size} rows)"
  end

  def assert_synthetic_patient!(dfn)
    row = RpmsRpc::Patient.find(dfn)
    refute_nil row, "DFN #{dfn} must exist on this disposable container seed data"
  end

  def server_now_fm
    require "rpms_rpc/fileman_date_parser"
    value = Array(client.call_rpc("ORWU DT", "NOW")).first.to_s
    RpmsRpc::FilemanDateParser.parse_datetime(value)&.then { |t| RpmsRpc::FilemanDateParser.format_datetime(t) } ||
      flunk("ORWU DT NOW did not yield a FileMan datetime")
  end
end
