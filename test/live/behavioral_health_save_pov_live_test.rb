# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/behavioral_health"
require "rpms_rpc/api/patient"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/fileman_date_parser"

# RpmsRpc::BehavioralHealth.save_pov over AMHG SAVE POV (POV^AMHGSVF, rpms-rpc#538).
# Replaces all POV and (mode E) Axis IV rows on each call. WRITES against a disposable
# local container only.
class BehavioralHealthSavePovLiveTest < LiveSpec::Test
  writes!

  # Synthetic seed patient; not used by save_visit (990033/990034) or other live write specs.
  DFN = 990_035
  BH_VISIT_FILE = "9002011"
  POV_FILE = "9002011.01"
  POV_XREF = "AD"
  POV_FROM = "0"
  POV_FIELDS = ".01;.02;.03;.04E"
  POV_FLAGS = "IP"
  POV_MAX = "25"
  AXIS_IV_FILE = "9002011.06101"
  AXIS_IV_FIELDS = ".01"
  AXIS_IV_FLAGS = "IP"
  AXIS_IV_MAX = "25"
  MHSS_PROBLEM_FILE = "9002012.2"
  PSYCHOSOCIAL_FILE = "9002012.9"

  CLINIC_FILE = "40.7"
  TYPE_OF_CONTACT_FILE = "9002012.1"
  ENCOUNTER_LOCATION_FILE = "9999999.06"
  COMMUNITY_FILE = "9999999.05"
  PROGRAM = "MENTAL HEALTH"
  APPOINTMENT_WITH = "WALK-IN"

  NARR_A = "SYNTH LIVE POV A"
  NARR_B = "SYNTH LIVE POV B"
  NARR_REPLACE = "SYNTH LIVE POV C"
  AXIS_III = "SYNTH LIVE AXIS III"
  AXIS_V_FIRST = 55
  AXIS_V_REPLACE = 70
  GAF_FIRST = "12"
  GROUP_NAME = ""

  def test_save_pov_files_then_replaces_diagnoses_and_axis_iv_via_ddr_readback
    assert_synthetic_patient!(DFN)
    clinic_ien, type_ien, _type_other, location_ien, community_ien, _community_other = discover_visit_reference_iens!
    provider = client.duz.to_s
    encounter = server_now_fm
    problem_iens = distinct_listed_iens!(MHSS_PROBLEM_FILE, count: 3, label: "MHSS problem")
    axis_iv_iens = distinct_listed_iens!(PSYCHOSOCIAL_FILE, count: 3, label: "psychosocial stressor")

    record_ien = RpmsRpc::BehavioralHealth.save_visit(
      provider: provider,
      program: PROGRAM,
      clinic: clinic_ien,
      type_of_contact: type_ien,
      encounter_date: encounter,
      encounter_location: location_ien,
      community_of_service: community_ien,
      appointment_with: APPOINTMENT_WITH,
      patient: DFN,
      group_name: GROUP_NAME
    )

    RpmsRpc::BehavioralHealth.save_pov(
      record_ien: record_ien,
      patient: DFN,
      diagnoses: [
        { problem: problem_iens[0], narrative: NARR_A },
        { problem: problem_iens[1], narrative: NARR_B }
      ],
      axis_iii: AXIS_III,
      axis_iv: [ axis_iv_iens[0], axis_iv_iens[1] ],
      axis_v: AXIS_V_FIRST,
      gaf: GAF_FIRST
    )

    assert_pov_rows_via_ddr!(
      record_ien,
      patient: DFN,
      want: [
        [ problem_iens[0], NARR_A ],
        [ problem_iens[1], NARR_B ]
      ]
    )
    assert_axis_iv_via_ddr!(record_ien, want: [ axis_iv_iens[0], axis_iv_iens[1] ])
    assert_visit_axis_fields_via_ddr!(
      record_ien,
      axis_v: AXIS_V_FIRST,
      gaf: GAF_FIRST,
      axis_iii: AXIS_III
    )

    RpmsRpc::BehavioralHealth.save_pov(
      record_ien: record_ien,
      patient: DFN,
      diagnoses: [ { problem: problem_iens[2], narrative: NARR_REPLACE } ],
      axis_iv: [ axis_iv_iens[2] ],
      axis_v: AXIS_V_REPLACE,
      gaf: "",
      axis_iii: ""
    )

    assert_pov_rows_via_ddr!(
      record_ien,
      patient: DFN,
      want: [ [ problem_iens[2], NARR_REPLACE ] ]
    )
    assert_axis_iv_via_ddr!(record_ien, want: [ axis_iv_iens[2] ])

    puts "\n#{persona}: BH visit #{record_ien} POV replace-all verified on DFN #{DFN}"
  end

  private

  def discover_visit_reference_iens!
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
    listed = RpmsRpc::DdrFileman.lister(file: file, fields: ".01", flags: "IP", max: "50")
    return [] if listed.nil? || listed[:error]

    listed[:entries].map { |row| row[:ien] }.grep(/\A[1-9]\d*\z/)
  end

  def flunk_no_entries!(file, label, listed)
    flunk "no #{label} IEN on file #{file} for this build " \
          "(DDR lister returned #{listed.size} usable rows); seed reference data or pick another disposable container"
  end

  def pov_lister_screen(record_ien)
    "I $P(^(0),U,3)=#{record_ien}"
  end

  def assert_pov_rows_via_ddr!(record_ien, patient:, want:)
    listed = RpmsRpc::DdrFileman.lister(
      file: POV_FILE, xref: POV_XREF, part: record_ien.to_s,
      from: POV_FROM, screen: pov_lister_screen(record_ien),
      fields: POV_FIELDS, flags: POV_FLAGS, max: POV_MAX
    )
    if listed.nil? || listed[:error]
      flunk "POV list read failed for visit #{record_ien}"
    end

    rows = listed[:entries].map do |entry|
      pieces = entry[:pieces]
      next nil if pieces.length < 4

      [
        pieces[0].to_s.split(";").first,
        pieces[1].to_s,
        pieces[2].to_s,
        pieces[3].to_s
      ]
    end.compact

    assert_equal want.length, rows.length,
                 "expected #{want.length} POV row(s) on visit #{record_ien} after replace-all filing"

    want.each do |problem_ien, narrative_ext|
      match = rows.find do |prob, pat, rec, narr|
        prob == problem_ien.to_s && pat == patient.to_s && rec == record_ien.to_s && narr == narrative_ext
      end
      refute_nil match, "expected problem #{problem_ien} with the sent narrative on visit #{record_ien}"
    end

    extra = rows.reject do |prob, pat, rec, narr|
      want.any? do |wprob, wnarr|
        wprob.to_s == prob && pat == patient.to_s && rec == record_ien.to_s && wnarr == narr
      end
    end
    assert_empty extra, "unexpected POV rows remain after replace-all on visit #{record_ien}"
  end

  def assert_axis_iv_via_ddr!(record_ien, want:)
    listed = RpmsRpc::DdrFileman.lister(
      file: AXIS_IV_FILE, iens: ",#{record_ien},",
      fields: AXIS_IV_FIELDS, flags: AXIS_IV_FLAGS, max: AXIS_IV_MAX
    )
    if listed.nil? || listed[:error]
      flunk "Axis IV list read failed for visit #{record_ien}"
    end

    filed = listed[:entries].map { |e| e[:pieces].first.to_s }.sort
    assert_equal want.map(&:to_s).sort, filed,
                 "Axis IV subfile must match the sent set (mode E replaces all prior rows)"
  end

  def assert_visit_axis_fields_via_ddr!(record_ien, axis_v:, gaf:, axis_iii: nil)
    got = RpmsRpc::DdrFileman.gets_entry(
      file: BH_VISIT_FILE, iens: "#{record_ien},", fields: ".14;1115", flags: "IE"
    )
    if got.nil? || got[:error]
      flunk "visit axis field read failed for #{record_ien}"
    end

    assert_equal axis_v.to_s, got.dig(:fields, ".14", :internal).to_s,
                 "AXIS V (.14) must match the value sent"
    assert_equal gaf.to_s, got.dig(:fields, "1115", :internal).to_s,
                 "GAF SCALE TYPE (1115) must match the value sent"
    return if axis_iii.nil? || axis_iii.to_s.empty?

    wp = RpmsRpc::DdrFileman.gets_entry(
      file: BH_VISIT_FILE, iens: "#{record_ien},", fields: "5301", flags: "E"
    )
    if wp.nil? || wp[:error]
      flunk "AXIS III (5301) read failed for visit #{record_ien}"
    end

    filed = wp.dig(:fields, "5301", :text)&.join("") || ""
    assert_equal axis_iii.to_s, filed,
                 "AXIS III (5301) word-processing text must match the line sent"
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
