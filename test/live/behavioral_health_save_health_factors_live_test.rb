# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/behavioral_health"
require "rpms_rpc/api/patient"
require "rpms_rpc/api/ddr_fileman"

# RpmsRpc::BehavioralHealth.save_health_factors over AMHG SAVE HEALTH FACTORS (HF^AMHGSVF).
# WRITES on a disposable container only; synthetic patient DFN 990037.
class BehavioralHealthSaveHealthFactorsLiveTest < LiveSpec::Test
  writes!

  DFN = 990_037
  HF_FILE = "9002011.08"
  HF_XREF = "AD"
  HF_FROM = "0"
  HF_FIELDS = ".01;.04;.06;81101"
  HF_FLAGS = "IP"
  HF_MAX = "25"

  PROGRAM = "MENTAL HEALTH"
  APPOINTMENT_WITH = "WALK-IN"
  CLINIC_FILE = "40.7"
  TYPE_OF_CONTACT_FILE = "9002012.1"
  ENCOUNTER_LOCATION_FILE = "9999999.06"
  COMMUNITY_FILE = "9999999.05"

  def test_save_health_factors_replace_all_on_edit_via_ddr_lister
    assert_synthetic_patient!(DFN)
    clinic_ien, type_ien, _t2, location_ien, community_ien, _c2 = discover_reference_iens!
    hf_name = discover_health_factor_name!
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

    RpmsRpc::BehavioralHealth.save_health_factors(
      record_ien: visit_ien,
      patient: DFN,
      mode: :edit,
      health_factors: [
        { name: hf_name, level: "YES", quantity: "1", comment: "SYN LIVE HF A" }
      ]
    )

    assert_hf_comment!(visit_ien, hf_name, "SYN LIVE HF A")

    RpmsRpc::BehavioralHealth.save_health_factors(
      record_ien: visit_ien,
      patient: DFN,
      mode: :edit,
      health_factors: [
        { name: hf_name, level: "NO", quantity: "2", comment: "SYN LIVE HF B" }
      ]
    )

    assert_hf_comment!(visit_ien, hf_name, "SYN LIVE HF B")

    puts "\n#{persona}: BH visit #{visit_ien} health factors saved on DFN #{DFN} (#{hf_name})"
  end

  private

  def discover_health_factor_name!
    listed = RpmsRpc::DdrFileman.lister(file: "9999999.64", fields: ".01", flags: "IP", max: "50")
    flunk "health factor type list failed" if listed.nil? || listed[:error]
    row = listed[:entries].find { |e| e[:pieces].first.to_s.length.positive? }
    flunk "no health factor type .01 on this build" unless row

    row[:pieces].first.to_s
  end

  def assert_hf_comment!(visit_ien, want_name, want_comment)
    listed = RpmsRpc::DdrFileman.lister(
      file: HF_FILE, xref: HF_XREF, part: visit_ien.to_s,
      from: HF_FROM, screen: "I $P(^(0),U,3)=#{visit_ien}",
      fields: HF_FIELDS, flags: HF_FLAGS, max: HF_MAX
    )
    flunk "HF list read failed for visit #{visit_ien}" if listed.nil? || listed[:error]

    match = listed[:entries].find do |entry|
      entry[:pieces].length >= 4 &&
        entry[:pieces][0].to_s == want_name &&
        entry[:pieces][3].to_s == want_comment
    end
    refute_nil match, "expected HF #{want_name.inspect} with comment #{want_comment.inspect} on visit #{visit_ien}"
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
