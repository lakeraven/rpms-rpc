# frozen_string_literal: true

require_relative "live_helper"
require "bigdecimal"
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
  BSD_PARAM_FILE = "9009020.2"
  DEVICE_FILE = "3.5"
  NULL_DEVICE_NAME = "ZZNULL"
  CONSECUTIVE_MISSES = 25

  def setup
    super
    @bsd_param_restores = ensure_file_room_printers!
  end

  def teardown
    restore_file_room_printers!(@bsd_param_restores) if @bsd_param_restores && client
  ensure
    super
  end

  def test_checkin_with_create_visit_yes_files_a_visit
    hloc = demo_clinic_ien
    ensure_checkin_visit_resource!(hloc)
    original = read_create_visit_flag_internal(hloc)

    begin
      file_create_visit_flag(hloc, "1")
      assert RpmsRpc::SchedulingSetup.creates_visit_at_checkin(hloc)

      start, appt_id = book_on_resource(45)
      high_water = visit_high_water_mark
      assert_visit_reader_sees_high_water!(high_water)

      assert_empty matching_new_visit_iens(high_water, PATIENT, hloc, start),
                   "DFN #{PATIENT} should have no new V VISIT at hospital location #{hloc} for that appointment before check-in"

      result = RpmsRpc::Scheduling.checkin_appointment(appt_id, checkin_time: start)
      assert result[:success], "check-in failed: #{result.inspect}"

      new_iens = matching_new_visit_iens(high_water, PATIENT, hloc, start)
      refute_empty new_iens, "check-in with CREATE VISIT YES should file at least one new V VISIT row"
    ensure
      restore_create_visit_flag!(hloc, original)
    end
  end

  def test_checkin_with_create_visit_no_does_not_file_a_visit
    hloc = demo_clinic_ien
    ensure_checkin_visit_resource!(hloc)
    original = read_create_visit_flag_internal(hloc)

    begin
      file_create_visit_flag(hloc, "0")
      refute RpmsRpc::SchedulingSetup.creates_visit_at_checkin(hloc)

      start, appt_id = book_on_resource(90)
      high_water = visit_high_water_mark
      assert_visit_reader_sees_high_water!(high_water)

      result = RpmsRpc::Scheduling.checkin_appointment(appt_id, checkin_time: start)
      assert result[:success], "check-in failed: #{result.inspect}"

      assert_empty matching_new_visit_iens(high_water, PATIENT, hloc, start),
                   "check-in with CREATE VISIT NO must not file a V VISIT for that patient, location and appointment"
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
    lines = Array(reply)
    if lines.any? { |line| line.match?(/BSDX14:/i) }
      flunk "BSDX ADD/EDIT RESOURCE refused #{RESOURCE_NAME} on hospital location #{hloc_ien}: #{reply.inspect}"
    end

    data_row = lines.find { |line| line.match?(/\A[1-9]\d*\^/) }
    flunk "BSDX ADD/EDIT RESOURCE gave no data row for #{RESOURCE_NAME}: #{reply.inspect}" unless data_row

    pieces = data_row.split("^", -1)
    unless pieces[0].to_i.positive? && pieces[1].to_s.empty?
      flunk "BSDX ADD/EDIT RESOURCE refused #{RESOURCE_NAME} on hospital location #{hloc_ien}: #{reply.inspect}"
    end

    resource = RpmsRpc::Scheduling.resources.find { |r| r[:name] == RESOURCE_NAME }
    flunk "BSDX ADD/EDIT RESOURCE answered but #{RESOURCE_NAME} is not in Scheduling.resources" unless resource
    assert_equal hloc_ien, resource[:hospital_location_id]
    resource
  end

  def null_device_ien
    @null_device_ien ||= begin
      listed = in_ciav do
        RpmsRpc::DdrFileman.lister(file: DEVICE_FILE, fields: "@;.01", flags: "IP", max: "500")
      end
      flunk "DDR LISTER on #{DEVICE_FILE} gave no reply" if listed.nil?
      flunk "DDR LISTER on #{DEVICE_FILE} errored: #{listed.inspect}" if listed[:error]

      entry = listed[:entries].find do |row|
        row[:pieces][0].to_s.split(";").first == NULL_DEVICE_NAME
      end
      flunk "no #{DEVICE_FILE} device named #{NULL_DEVICE_NAME} on this build" unless entry

      entry[:ien].to_s
    end
  end

  def ensure_file_room_printers!
    null_ien = null_device_ien
    listed = in_ciav do
      RpmsRpc::DdrFileman.lister(file: BSD_PARAM_FILE, fields: "@;.01I;.05I", flags: "IP", max: "500")
    end
    flunk "DDR LISTER on #{BSD_PARAM_FILE} gave no reply" if listed.nil?
    flunk "DDR LISTER on #{BSD_PARAM_FILE} errored: #{listed.inspect}" if listed[:error]

    restores = []
    listed[:entries].each do |entry|
      printer = entry[:pieces][1].to_s.split(";").first
      next unless printer.to_s.strip.empty?

      param_ien = entry[:ien]
      rows = [ { file: BSD_PARAM_FILE, field: ".05", iens: "#{param_ien},", value: null_ien } ]
      got = in_ciav { RpmsRpc::DdrFileman.filer(mode: "EDIT", rows: rows) }
      assert got && got[:success],
             "DDR FILER on #{BSD_PARAM_FILE} #{param_ien} .05=#{null_ien}: #{got.inspect}"
      restores << { ien: param_ien, original: "" }
    end
    restores
  end

  def restore_file_room_printers!(restores)
    restores.each do |row|
      value = row[:original].to_s.empty? ? "@" : row[:original]
      filer_rows = [ { file: BSD_PARAM_FILE, field: ".05", iens: "#{row[:ien]},", value: value } ]
      got = in_ciav { RpmsRpc::DdrFileman.filer(mode: "EDIT", rows: filer_rows) }
      assert got && got[:success],
             "DDR FILER restore on #{BSD_PARAM_FILE} #{row[:ien]} .05: #{got.inspect}"

      current = read_bsd_param_printer_internal(row[:ien])
      assert_equal row[:original].to_s, current,
                   "BSD PARAMETERS #{BSD_PARAM_FILE} IEN #{row[:ien]} .05 was not restored"
    end
  end

  def read_bsd_param_printer_internal(param_ien)
    got = in_ciav do
      RpmsRpc::DdrFileman.gets_entry(file: BSD_PARAM_FILE, iens: "#{param_ien},", fields: ".05", flags: "I")
    end
    flunk "DDR GETS on #{BSD_PARAM_FILE} #{param_ien} .05 gave no reply" if got.nil?
    flunk "DDR GETS on #{BSD_PARAM_FILE} #{param_ien} .05 refused: #{got.inspect}" if got[:error]

    got.dig(:fields, ".05", :internal).to_s
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

  def visit_high_water_mark
    listed = in_ciav do
      RpmsRpc::DdrFileman.lister(file: VISIT_FILE, fields: "@", flags: "IP", max: "500")
    end
    flunk "DDR LISTER on #{VISIT_FILE} gave no reply" if listed.nil?
    flunk "DDR LISTER on #{VISIT_FILE} errored: #{listed.inspect}" if listed[:error]

    seed = listed[:entries].map { |e| e[:ien].to_i }.max
    seed = 1 if seed.nil? || seed.zero?

    high = seed
    misses = 0
    ien = seed
    while misses < CONSECUTIVE_MISSES
      if read_visit_fields(ien)
        high = ien
        misses = 0
      else
        misses += 1
      end
      ien += 1
    end
    high
  end

  def assert_visit_reader_sees_high_water!(high_water)
    fields = read_visit_fields(high_water)
    flunk "V VISIT high-water IEN #{high_water} is missing (reader cannot see existing rows)" unless fields
    refute_empty fields.dig(".01", :internal).to_s.strip,
                 "V VISIT high-water IEN #{high_water} has a blank .01 (reader is not working)"
  end

  def matching_new_visit_iens(high_water, patient_dfn, hospital_location_id, appt_start)
    assert_visit_reader_sees_high_water!(high_water)

    expected_fm = RpmsRpc::FilemanDateParser.to_fileman(appt_start)
    iens = []
    misses = 0
    ien = high_water + 1
    while misses < CONSECUTIVE_MISSES
      fields = read_visit_fields(ien)
      if fields
        if fields.dig(".05", :internal).to_s == patient_dfn.to_s &&
           fields.dig(".22", :internal).to_s == hospital_location_id.to_s &&
           fileman_values_equal?(fields.dig(".26", :internal), expected_fm)
          iens << ien.to_s
        end
        misses = 0
      else
        misses += 1
      end
      ien += 1
    end
    iens
  end

  def read_visit_fields(ien)
    got = in_ciav do
      RpmsRpc::DdrFileman.gets_entry(file: VISIT_FILE, iens: "#{ien},", fields: ".01;.05;.22;.26", flags: "I")
    end
    flunk "DDR GETS on #{VISIT_FILE} IEN #{ien} gave no reply" if got.nil?
    return nil if got[:error]

    internal = got.dig(:fields, ".01", :internal).to_s.strip
    return nil if internal.empty?

    got[:fields]
  end

  def fileman_values_equal?(left, right)
    BigDecimal(normalize_fileman(left)) == BigDecimal(normalize_fileman(right))
  rescue ArgumentError
    normalize_fileman(left) == normalize_fileman(right)
  end

  def normalize_fileman(value)
    text = value.to_s.strip
    return text if text.empty? || !text.include?(".")

    date, time = text.split(".", 2)
    time = time.sub(/0+\z/, "")
    time.empty? ? date : "#{date}.#{time}"
  end
end
