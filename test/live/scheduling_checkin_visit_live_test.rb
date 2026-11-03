# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/scheduling"
require "rpms_rpc/api/scheduling_setup"
require "rpms_rpc/api/ddr_fileman"

# CHECKIN^BSDX25 creates a V VISIT (#9000010) only when the clinic's
# hospital-location companion (#9009017.2) has CREATE VISIT (.09) set (rpms-rpc#530).
class SchedulingCheckinVisitLiveTest < LiveSpec::Test
  writes!

  PATIENT = 3
  CLINIC_NAME = "DEMO IHS CLINIC"
  RESOURCE_NAME = "LIVE SPEC CHECKIN VISIT"
  VISIT_FILE = "9000010"
  CLINIC_FLAG_FILE = "9009017.2"

  def test_checkin_with_create_visit_yes_files_a_visit
    assert_matching_visits_reader_sees_existing_row!

    hloc = demo_clinic_ien
    ensure_checkin_visit_resource!(hloc)
    original = read_create_visit_flag_internal(hloc)

    begin
      file_create_visit_flag(hloc, "1")
      assert RpmsRpc::SchedulingSetup.creates_visit_at_checkin(hloc)

      start, appt_id = book_on_resource(45)
      day = start.to_date
      before_iens = matching_visits(PATIENT, hloc, day)
      assert_empty before_iens,
                   "DFN #{PATIENT} should have no V VISIT at hospital location #{hloc} on #{day} before check-in"

      result = RpmsRpc::Scheduling.checkin_appointment(appt_id, checkin_time: start)
      assert result[:success], "check-in failed: #{result.inspect}"

      after_iens = matching_visits(PATIENT, hloc, day)
      new_iens = after_iens - before_iens
      refute_empty new_iens, "check-in with CREATE VISIT YES should file at least one new V VISIT row"
    ensure
      restore_create_visit_flag!(hloc, original)
    end
  end

  def test_checkin_with_create_visit_no_does_not_file_a_visit
    assert_matching_visits_reader_sees_existing_row!

    hloc = demo_clinic_ien
    ensure_checkin_visit_resource!(hloc)
    original = read_create_visit_flag_internal(hloc)

    begin
      file_create_visit_flag(hloc, "0")
      refute RpmsRpc::SchedulingSetup.creates_visit_at_checkin(hloc)

      start, appt_id = book_on_resource(90)
      day = start.to_date
      assert_empty matching_visits(PATIENT, hloc, day),
                   "DFN #{PATIENT} should have no V VISIT at hospital location #{hloc} on #{day} before check-in"

      result = RpmsRpc::Scheduling.checkin_appointment(appt_id, checkin_time: start)
      assert result[:success], "check-in failed: #{result.inspect}"

      assert_empty matching_visits(PATIENT, hloc, day),
                   "check-in with CREATE VISIT NO must not file a V VISIT for that patient, location and date"
    ensure
      restore_create_visit_flag!(hloc, original)
    end
  end

  private

  def demo_clinic_ien
    @demo_clinic_ien ||= begin
      loc = RpmsRpc::Scheduling.hospital_locations.find { |h| h[:location] == CLINIC_NAME }
      flunk "no hospital location named #{CLINIC_NAME} in Scheduling.hospital_locations" unless loc
      ien = loc[:location_ien]
      flunk "#{CLINIC_NAME} has a blank hospital location IEN" if ien.to_s.empty?
      ien
    end
  end

  def ensure_checkin_visit_resource!(hloc_ien)
    existing = RpmsRpc::Scheduling.resources.find { |r| r[:name] == RESOURCE_NAME }
    return existing if existing

    reply = client.with_context(RpmsRpc::Scheduling::CONTEXT) do
      client.call_rpc("BSDX ADD/EDIT RESOURCE", "0|#{RESOURCE_NAME}|NO|#{hloc_ien}|15")
    end
    text = Array(reply).join
    if text.match?(/BSDX14:/i) || text.match?(/ERRORTEXT/i)
      flunk "BSDX ADD/EDIT RESOURCE refused #{RESOURCE_NAME} on hospital location #{hloc_ien}: #{reply.inspect}"
    end

    resource = RpmsRpc::Scheduling.resources.find { |r| r[:name] == RESOURCE_NAME }
    flunk "BSDX ADD/EDIT RESOURCE answered but #{RESOURCE_NAME} is not in Scheduling.resources" unless resource
    assert_equal hloc_ien, resource[:hospital_location_id]
    resource
  end

  def in_ciav(&block)
    client.with_context(RpmsRpc::SchedulingSetup::CONTEXT, &block)
  end

  def read_create_visit_flag_internal(hloc_ien)
    got = in_ciav do
      RpmsRpc::DdrFileman.gets_entry(file: CLINIC_FLAG_FILE, iens: "#{hloc_ien},", fields: ".09", flags: "IE")
    end
    flunk "DDR GETS on #{CLINIC_FLAG_FILE} #{hloc_ien} gave no reply" if got.nil?
    flunk "DDR GETS on #{CLINIC_FLAG_FILE} #{hloc_ien} refused: #{got.inspect}" if got[:error]

    got.dig(:fields, ".09", :internal).to_s
  end

  def file_create_visit_flag(hloc_ien, internal)
    value = internal.to_s.empty? ? "@" : internal.to_s
    rows = [ { file: CLINIC_FLAG_FILE, field: ".09", iens: "#{hloc_ien},", value: value } ]
    got = in_ciav { RpmsRpc::DdrFileman.filer(mode: "EDIT", rows: rows) }
    assert got && got[:success], "DDR FILER on #{CLINIC_FLAG_FILE} #{hloc_ien} .09=#{value}: #{got.inspect}"
  end

  def restore_create_visit_flag!(hloc_ien, original_internal)
    file_create_visit_flag(hloc_ien, original_internal)
    assert_equal original_internal, read_create_visit_flag_internal(hloc_ien),
                 "the clinic's #{CLINIC_FLAG_FILE} .09 CREATE VISIT flag was not restored"
  end

  def book_on_resource(day_offset_base)
    40.times do
      day = Date.today + day_offset_base + rand(21)
      day += 1 while day.saturday? || day.sunday?
      start = Time.new(day.year, day.month, day.day, 13 + rand(4), [ 0, 15, 30, 45 ].sample)
      reply = RpmsRpc::Scheduling.add_appointment(patient_dfn: PATIENT, resource: RESOURCE_NAME, start_time: start,
                                                  end_time: start + 900, length_minutes: 15)
      next unless reply && reply[:success]

      return [ start, reply[:appointment_id] ]
    end
    flunk "no open slot #{day_offset_base}-#{day_offset_base + 20} days out for DFN #{PATIENT} on #{RESOURCE_NAME}"
  end

  def assert_matching_visits_reader_sees_existing_row!
    listed = in_ciav do
      RpmsRpc::DdrFileman.lister(file: VISIT_FILE, fields: "@;.01I;.05I;.22I", flags: "IP", max: "1")
    end
    flunk "DDR LISTER on #{VISIT_FILE} (sample row) gave no reply" if listed.nil?
    flunk "DDR LISTER on #{VISIT_FILE} (sample row) errored: #{listed.inspect}" if listed[:error]

    entry = listed[:entries].first
    flunk "this build has no V VISIT (#{VISIT_FILE}) rows; cannot verify the visit lister reads data" unless entry

    pieces = entry[:pieces]
    flunk "sample V VISIT row #{entry[:ien]} has too few LIST^DIC pieces: #{pieces.inspect}" if pieces.length < 3

    patient_dfn = pieces[1].to_s.split(";").first
    hospital_location_id = pieces[2].to_s.split(";").first
    fm_day_str = pieces[0].to_s.split(".", 2).first
    day = RpmsRpc::FilemanDateParser.parse_date(fm_day_str)
    flunk "sample V VISIT row #{entry[:ien]} has unparseable visit date #{pieces[0].inspect}" unless day

    ien = entry[:ien].to_s
    matches = matching_visits(patient_dfn, hospital_location_id, day)
    assert_includes matches, ien,
                    "matching_visits must find sample V VISIT IEN #{ien} (DFN #{patient_dfn}, hospital location #{hospital_location_id}, #{day})"
  end

  def matching_visits(patient_dfn, hospital_location_id, day)
    fm_day = RpmsRpc::FilemanDateParser.to_fileman(day).to_s
    screen = "I ($P(^(0),U,5)=#{patient_dfn})&($P(^(0),U,22)=#{hospital_location_id})"
    listed = in_ciav do
      RpmsRpc::DdrFileman.lister(file: VISIT_FILE, fields: "@;.01I;.05I;.22I", flags: "IP", max: "500",
                                 screen: screen)
    end
    flunk "DDR LISTER on #{VISIT_FILE} for DFN #{patient_dfn} at hospital location #{hospital_location_id} on #{day} gave no reply" if listed.nil?
    flunk "DDR LISTER on #{VISIT_FILE} for DFN #{patient_dfn} errored: #{listed.inspect}" if listed[:error]
    flunk "DDR LISTER on #{VISIT_FILE} for DFN #{patient_dfn} at hospital location #{hospital_location_id} on #{day} was truncated (:more); increase max or narrow the screen" if listed[:more]

    listed[:entries].filter_map do |entry|
      pieces = entry[:pieces]
      next unless pieces.length >= 3

      visit_day = pieces[0].to_s.split(".", 2).first
      next unless visit_day == fm_day
      next unless pieces[1].to_s.split(";").first == patient_dfn.to_s
      next unless pieces[2].to_s.split(";").first == hospital_location_id.to_s

      entry[:ien].to_s
    end
  end
end
