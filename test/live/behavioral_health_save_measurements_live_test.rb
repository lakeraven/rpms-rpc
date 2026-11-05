# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/behavioral_health"
require "rpms_rpc/api/patient"
require "rpms_rpc/api/ddr_fileman"

# RpmsRpc::BehavioralHealth.save_measurements over AMHG SAVE MEASUREMENTS (MSR^AMHGSVF).
# WRITES on a disposable container only; synthetic patient DFN 990038.
class BehavioralHealthSaveMeasurementsLiveTest < LiveSpec::Test
  writes!

  DFN = 990_038
  MSR_FILE = "9002011.12"
  MSR_XREF = "AD"
  MSR_FROM = "0"
  MSR_FIELDS = ".01;.04;1204"
  MSR_FLAGS = "IP"
  MSR_MAX = "25"

  PROGRAM = "MENTAL HEALTH"
  APPOINTMENT_WITH = "WALK-IN"
  CLINIC_FILE = "40.7"
  TYPE_OF_CONTACT_FILE = "9002012.1"
  ENCOUNTER_LOCATION_FILE = "9999999.06"
  COMMUNITY_FILE = "9999999.05"

  def test_save_measurements_replace_all_on_edit_via_ddr_lister
    assert_synthetic_patient!(DFN)
    clinic_ien, type_ien, _t2, location_ien, community_ien, _c2 = discover_reference_iens!
    msr_name = discover_measurement_name!
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

    RpmsRpc::BehavioralHealth.save_measurements(
      record_ien: visit_ien,
      patient: DFN,
      mode: :edit,
      measurements: [
        { name: msr_name, value: "42", provider: provider }
      ]
    )

    assert_msr_value!(visit_ien, msr_name, "42")

    RpmsRpc::BehavioralHealth.save_measurements(
      record_ien: visit_ien,
      patient: DFN,
      mode: :edit,
      measurements: [
        { name: msr_name, value: "55", provider: provider }
      ]
    )

    assert_msr_value!(visit_ien, msr_name, "55")

    puts "\n#{persona}: BH visit #{visit_ien} measurements saved on DFN #{DFN} (#{msr_name})"
  end

  private

  def discover_measurement_name!
    listed = RpmsRpc::DdrFileman.lister(file: "9999999.07", fields: ".01", flags: "IP", max: "50")
    flunk "measurement type list failed" if listed.nil? || listed[:error]
    row = listed[:entries].find { |e| e[:pieces].first.to_s.length.positive? }
    flunk "no measurement type .01 on this build" unless row

    row[:pieces].first.to_s
  end

  def assert_msr_value!(visit_ien, want_name, want_value)
    listed = RpmsRpc::DdrFileman.lister(
      file: MSR_FILE, xref: MSR_XREF, part: visit_ien.to_s,
      from: MSR_FROM, screen: "I $P(^(0),U,3)=#{visit_ien}",
      fields: MSR_FIELDS, flags: MSR_FLAGS, max: MSR_MAX
    )
    flunk "MSR list read failed for visit #{visit_ien}" if listed.nil? || listed[:error]

    match = listed[:entries].find do |entry|
      entry[:pieces].length >= 2 &&
        entry[:pieces][0].to_s == want_name &&
        entry[:pieces][1].to_s == want_value
    end
    refute_nil match, "expected MSR #{want_name.inspect} value #{want_value.inspect} on visit #{visit_ien}"
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
    flunk "no #{label} IEN on file #{file} for this build"
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
