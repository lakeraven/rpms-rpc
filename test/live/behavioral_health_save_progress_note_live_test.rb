# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/behavioral_health"
require "rpms_rpc/api/patient"
require "rpms_rpc/api/ddr_fileman"

# RpmsRpc::BehavioralHealth.save_progress_note over AMHG SAVE PROGRESS NOTES
# (PN^AMHGSVF, rpms-rpc#539). WRITES on a disposable container only.
class BehavioralHealthSaveProgressNoteLiveTest < LiveSpec::Test
  writes!

  DFN = 990_033
  BH_VISIT_FILE = "9002011"
  PLACEMENT_FILE = "9002013.6"
  PROGRAM = "MENTAL HEALTH"
  APPOINTMENT_WITH = "WALK-IN"

  CLINIC_FILE = "40.7"
  TYPE_OF_CONTACT_FILE = "9002012.1"
  ENCOUNTER_LOCATION_FILE = "9999999.06"
  COMMUNITY_FILE = "9999999.05"

  READBACK_SCALAR_FIELDS = "2101;.17;.18"
  CHIEF_COMPLAINT = "SYNTH CC LIVE"
  REFERRED_TO = "SYN REF LIVE"

  def test_save_progress_note_multiline_note_comment_placement_and_clears
    assert_synthetic_patient!(DFN)
    clinic_ien, type_ien, _type_other, location_ien, community_ien, _community_other = discover_reference_iens!
    placement_ien = discover_active_placement_ien!
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

    long_line = "SYNTH #{'padding ' * 8}end"
    note = "Line one.\nSecond.\n\n#{long_line}\n"
    comment = "SYNTH comment line A\nSYNTH comment line B"

    RpmsRpc::BehavioralHealth.save_progress_note(
      record_ien: visit_ien,
      patient: DFN,
      chief_complaint: CHIEF_COMPLAINT,
      note: note,
      comment: comment,
      placement_disposition: placement_ien,
      referred_to: REFERRED_TO
    )

    soap_rows = raw_soap_rows(visit_ien)
    refute_empty soap_rows
    soap_rows.each do |row|
      next unless row.include?("\n")

      assert row.end_with?("\n"), "each LF-terminated SOAP row must keep the LF"
    end
    wrapped = soap_rows.find { |r| r.length > 65 && r.include?(" ") && !r.end_with?("\n") }
    refute_nil wrapped, "expected ARRAYT wrap after a space past 65 characters"
    assert_equal note, soap_rows.join("")

    comm_rows = RpmsRpc::BehavioralHealth.visit_comment_appointment(visit_ien)
    assert_equal comment, comm_rows.join("")

    scalars = read_scalar_fields(visit_ien)
    assert_equal CHIEF_COMPLAINT, scalars.fetch("2101")
    assert_equal placement_ien.to_s, scalars.fetch(".17")
    assert_equal REFERRED_TO, scalars.fetch(".18")

    prior_comment = comm_rows.join("")

    RpmsRpc::BehavioralHealth.save_progress_note(
      record_ien: visit_ien,
      patient: DFN,
      chief_complaint: CHIEF_COMPLAINT,
      note: "SYNTH note after blank comment.",
      comment: "",
      placement_disposition: placement_ien,
      referred_to: REFERRED_TO
    )

    after_comment = RpmsRpc::BehavioralHealth.visit_comment_appointment(visit_ien).join("")
    assert_equal prior_comment, after_comment,
                 "empty comment must not change stored 8101 (stock AMHGEVF)"

    RpmsRpc::BehavioralHealth.save_progress_note(
      record_ien: visit_ien,
      patient: DFN,
      chief_complaint: "",
      note: "SYNTH note after clearing scalars.",
      comment: "",
      placement_disposition: "",
      referred_to: ""
    )

    cleared = read_scalar_fields(visit_ien)
    assert_equal "", cleared.fetch("2101")
    assert_equal "", cleared.fetch(".17")
    assert_equal "", cleared.fetch(".18")

    puts "\n#{persona}: BH visit #{visit_ien} progress note saved on DFN #{DFN} " \
         "(placement #{placement_ien}, multiline SOAP verified via AMHG GET VISIT SOAP)"
  end

  private

  def raw_soap_rows(visit_ien)
    frame = client.call_rpc_global_array("AMHG GET VISIT SOAP", visit_ien.to_s)
    body = frame.is_a?(Array) ? frame.join("\n") : frame.to_s
    body = body.split("\x00", 2).last if body.include?("\x00")
    body = body.split("\x1f", 2).first.to_s
    parts = body.split("\x1e")
    header = parts.first.to_s
    flunk "unexpected SOAP header: #{header.inspect}" unless header.include?("Soap")

    parts.drop(1).reject(&:empty?)
  end

  def read_scalar_fields(visit_ien)
    got = RpmsRpc::DdrFileman.gets_entry(
      file: BH_VISIT_FILE, iens: "#{visit_ien},",
      fields: READBACK_SCALAR_FIELDS, flags: "I"
    )
    flunk "DDR GETS scalar fields on visit #{visit_ien}" if got.nil? || got[:error]

    got[:fields].transform_values { |v| v[:internal].to_s }
  end

  def discover_active_placement_ien!
    listed = RpmsRpc::DdrFileman.lister(
      file: PLACEMENT_FILE, fields: ".01;.02", flags: "IP", max: "50"
    )
    flunk "DDR LISTER on #{PLACEMENT_FILE} failed" if listed.nil? || listed[:error]

    row = listed[:entries].find do |entry|
      entry[:pieces].length >= 2 && entry[:pieces][1].to_s != "1"
    end
    flunk "no active placement disposition on #{PLACEMENT_FILE} (.02 not 1)" unless row

    row[:ien]
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
          "(DDR lister returned #{listed.size} usable rows)"
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
