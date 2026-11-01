# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/context_scope"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/patient"
require "rpms_rpc/fileman_date_parser"

begin
  require "rpms_rpc/api/behavioral_health/wellness"
rescue LoadError
  nil
end

# RpmsRpc::BehavioralHealth::Wellness — AMHG SAVE SCREENING and AMHG SAVE
# MEASUREMENTS (rpms-rpc#540). WRITES on a disposable local container only.
class BehavioralHealthWellnessLiveTest < LiveSpec::Test
  writes!

  DFN = 990_045
  BH_VISIT_FILE = "9002011"
  PROGRAM = "MENTAL HEALTH"
  PROGRAM_INTERNAL = "M"

  CLINIC_FILE = "40.7"
  TYPE_OF_CONTACT_FILE = "9002012.1"
  ENCOUNTER_LOCATION_FILE = "9999999.06"
  COMMUNITY_FILE = "9999999.05"

  SCREENING_DDR_FIELDS =
    ".08;1112;1401;1402;1403;1404;1405;1406;1407;1408;1409;1410;1501;1601;1701;1901;2001".freeze

  SYNTH_DEPRESSION_COMMENT = "Synthetic live depression screening note"
  MSR_RPC = "AMHG GET VISIT MSR DATA ENTRY"
  RS = "\x1e"
  US = "\x1f"

  def test_wellness_saves_screening_then_measurements_with_readback
    wellness = wellness_module!
    assert_synthetic_patient!(DFN)
    clinic_ien, type_ien, location_ien, community_ien = discover_reference_iens!
    provider = client.duz.to_s
    encounter = server_now_fm

    record_ien = create_bh_visit_via_amhg!(
      provider: provider,
      clinic_ien: clinic_ien,
      type_ien: type_ien,
      encounter: encounter,
      location_ien: location_ien,
      community_ien: community_ien
    )

    alcohol_comment = "Synthetic live alcohol screening note"
    wellness.save_screening(
      record_ien,
      patient: DFN,
      screenings: {
        alcohol: { result: "N", provider: provider, comment: alcohol_comment }
      }
    )

    alcohol_after_first = screening_ddr_fields(record_ien)
    assert_equal "N", alcohol_after_first.fetch("1403"), "alcohol filed on first save"
    assert_equal provider, alcohol_after_first.fetch("1404"), "alcohol provider on first save"
    assert_equal alcohol_comment, alcohol_after_first.fetch("1601"), "alcohol comment on first save"

    wellness.save_screening(
      record_ien,
      patient: DFN,
      screenings: {
        depression: { result: "P", provider: provider, comment: SYNTH_DEPRESSION_COMMENT }
      }
    )

    after = screening_ddr_fields(record_ien)
    assert_equal "P", after.fetch("1405"), "depression result internal POSITIVE"
    assert_equal provider, after.fetch("1406"), "depression provider"
    assert_equal SYNTH_DEPRESSION_COMMENT, after.fetch("1701"), "depression comment"
    assert_equal alcohol_after_first.fetch("1403"), after.fetch("1403"), "alcohol result unchanged"
    assert_equal alcohol_after_first.fetch("1404"), after.fetch("1404"), "alcohol provider unchanged"
    assert_equal alcohol_after_first.fetch("1601"), after.fetch("1601"), "alcohol comment unchanged"

    filed = wellness.save_measurements(
      record_ien,
      patient: DFN,
      measurements: [
        { type: "PHQ9", value: 14, provider: provider },
        { type: "GAD7", value: 9, provider: provider }
      ]
    )

    phq = filed.find { |r| r[:type] == "PHQ9" }
    gad = filed.find { |r| r[:type] == "GAD7" }
    refute_nil phq, "PHQ9 in save_measurements read-back"
    refute_nil gad, "GAD7 in save_measurements read-back"
    assert_equal 14, phq[:value]
    assert_equal 9, gad[:value]
    assert_equal provider, phq.dig(:provider, :ien)
    assert_equal provider, gad.dig(:provider, :ien)

    msr = msr_rows_via_rpc(record_ien)
    assert_equal 14, msr.find { |r| r[:type] == "PHQ9" }&.fetch(:value),
                 "PHQ9 via #{MSR_RPC}"
    assert_equal 9, msr.find { |r| r[:type] == "GAD7" }&.fetch(:value),
                 "GAD7 via #{MSR_RPC}"

    edited = wellness.save_measurements(
      record_ien,
      patient: DFN,
      measurements: [
        { type: "PHQ9", value: 15, provider: provider },
        { type: "GAD7", value: 9, provider: provider }
      ]
    )

    assert_equal 15, edited.find { |r| r[:type] == "PHQ9" }&.fetch(:value)
    assert_equal 9, edited.find { |r| r[:type] == "GAD7" }&.fetch(:value),
                 "GAD7 must survive PHQ9 edit (mode A, not E)"

    puts "\n#{persona}: BH visit #{record_ien} on DFN #{DFN} screening and measurements via Wellness (#540)"
  end

  private

  def wellness_module!
    mod = RpmsRpc::BehavioralHealth.const_defined?(:Wellness, false) &&
          RpmsRpc::BehavioralHealth::Wellness
    flunk "RpmsRpc::BehavioralHealth::Wellness is not implemented (rpms-rpc#540)" unless mod

    mod
  end

  def create_bh_visit_via_amhg!(provider:, clinic_ien:, type_ien:, encounter:, location_ien:, community_ien:)
    wire =
      "A||#{provider}|#{PROGRAM_INTERNAL}|#{clinic_ien}|#{type_ien}||#{encounter}|" \
      "#{location_ien}|W|#{community_ien}|#{DFN}||||"
    reply = RpmsRpc::ContextScope.scoped(client, "AMHGRPC") do
      client.call_rpc_global_array("AMHG SAVE VISIT", wire)
    end
    ien = parse_amhg_save_reply_ien(reply)
    refute_empty ien.to_s, "AMHG SAVE VISIT must return a record IEN"
    ien.to_s
  end

  def parse_amhg_save_reply_ien(reply)
    lines = Array(reply).join("\n").split(RS)
    header = lines.first.to_s
    return lines[1].to_s if header.include?("BMXIEN") || header.include?("Result")

    lines[1].to_s
  end

  def discover_reference_iens!
    clinic = first_listed_ien!(CLINIC_FILE, label: "BH clinic")
    type = first_listed_ien!(TYPE_OF_CONTACT_FILE, label: "type of contact")
    location = first_listed_ien!(ENCOUNTER_LOCATION_FILE, label: "location of encounter")
    community = first_listed_ien!(COMMUNITY_FILE, label: "community of service")
    [ clinic, type, location, community ]
  end

  def first_listed_ien!(file, label:)
    listed = list_file(file)
    flunk_no_entries!(file, label, listed) if listed.empty?

    listed.first
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

  def screening_ddr_fields(ien)
    filed = RpmsRpc::DdrFileman.gets_entry(
      file: BH_VISIT_FILE, iens: "#{ien},", fields: SCREENING_DDR_FIELDS, flags: "I"
    )
    flunk "DDR GETS screening fields on visit #{ien} failed" if filed.nil? || filed[:error]

    filed[:fields].transform_values { |v| v[:internal].to_s }
  end

  def msr_rows_via_rpc(record_ien)
    reply = RpmsRpc::ContextScope.scoped(client, "AMHGRPC") do
      client.call_rpc_global_array(MSR_RPC, record_ien.to_s)
    end
    parse_msr_read(reply)
  end

  def parse_msr_read(reply)
    text = Array(reply).join("\n")
    lines = text.split(RS).reject(&:empty?)
    lines.shift if lines.first.to_s.include?("Measurement")
    lines.map do |line|
      type_ien, type_code, description, value, prov_ien, prov_name = line.split("^", 6)
      {
        type: type_code,
        description: description,
        value: Integer(value),
        provider: { ien: prov_ien, name: prov_name }
      }
    end
  end

  def server_now_fm
    value = Array(client.call_rpc("ORWU DT", "NOW")).first.to_s
    RpmsRpc::FilemanDateParser.parse_datetime(value)&.then { |t| RpmsRpc::FilemanDateParser.format_datetime(t) } ||
      flunk("ORWU DT NOW did not yield a FileMan datetime")
  end
end
