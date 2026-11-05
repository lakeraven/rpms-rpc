# frozen_string_literal: true

# Client half of `rake wire:capture_writes` (issue #565). Host mode only: the
# rake task runs this on this machine against a disposable loopback broker.
#
#   LIVE_DISPOSABLE=1 VISTA_RPC_ENV=development RPMS_RPC_LIB=<rpms-rpc/lib> \
#     BROKER_HOST=127.0.0.1 BROKER_PORT=9100 \
#     RPMS_ACCESS=SYS123 RPMS_VERIFY=... ruby bin/wire_capture_writes_driver.rb
#
# Signs on as the setup persona (RPMS_ACCESS / RPMS_VERIFY), provisions the
# synthetic resource and file-room printer when they are absent, books three
# appointments at the next open weekday times (a refused time is skipped, not
# captured), then signs on as PROV123 through CiaClient's development
# fallback (this script does not set that pair) and checks in, cancels, and
# no-shows. Each persona's session DUZ is recorded under the access code
# actually signed on as. Check-in, cancel, and no-show read the same DDR GETS
# entries immediately before the write (read_before) and after it (read_back);
# check-in also reads HOSPITAL LOCATION #44.003. A write the API reports
# refused ({ success: false } or nil) is a step error. One JSON document on
# stdout. A failed step is an "error" field in that document. Verify codes
# and other env values are never printed.
require "json"
require "date"

# rpms-rpc references IO::TimeoutError (Ruby >= 3.2); keep the rescue paths
# valid on the older rubies the read driver still documents.
IO::TimeoutError = Class.new(IOError) unless IO.const_defined?(:TimeoutError)

lib = ENV["RPMS_RPC_LIB"] or abort("set RPMS_RPC_LIB to rpms-rpc/lib")
$LOAD_PATH.unshift(lib)
require "rpms_rpc/version"
require "rpms_rpc/cia_client"
require "rpms_rpc/wire_capture"
require "rpms_rpc/api/scheduling"
require "rpms_rpc/api/ddr_fileman"

# The scheduling-write scenario. Talks only through the public API and the
# recording wrapper. Does not write fixtures; the rake task does that.
class WriteCaptureDriver
  LOOPBACK_HOSTS = %w[127.0.0.1 localhost ::1].freeze
  SYNTHETIC_PERSONAS = %w[SYS123 PROV123].freeze
  PILOT_PERSONA = "PROV123"
  PATIENT_DFN = 3
  RESOURCE_NAME = "ZZ PILOT SCHED CAPTURE"
  HOSPITAL_LOCATION_ID = "3"
  RESOURCE_RPC_ARG = "0|#{RESOURCE_NAME}|NO|#{HOSPITAL_LOCATION_ID}|15"
  LENGTH_MINUTES = 30
  CANCEL_REASON = 5
  CANCEL_TYPE = "PC"
  CANCEL_NOTE = "pilot live capture"
  ADD_RPC = "BSDX ADD NEW APPOINTMENT"
  CHECKIN_RPC = "BSDX CHECKIN APPOINTMENT"
  CANCEL_RPC = "BSDX CANCEL APPOINTMENT"
  NOSHOW_RPC = "BSDX NOSHOW"
  DDR_RPC = "DDR GETS ENTRY DATA"
  WRITE_RPCS = [ ADD_RPC, CHECKIN_RPC, CANCEL_RPC, NOSHOW_RPC ].freeze
  APPOINTMENT_FILE = "9002018.4"
  APPOINTMENT_FIELDS = ".01;.03;.05;.07;.1;.12"
  PATIENT_APPOINTMENT_FILE = "2.98"
  PATIENT_APPOINTMENT_FIELDS = ".01;3;14;16"
  DEVICE_FILE = "3.5"
  NULL_DEVICE = "ZZNULL"
  PARAMETER_FILE = "9009020.2"
  READ_BACK_COUNT = 2
  CAUSATION_RPCS = [ CHECKIN_RPC, CANCEL_RPC, NOSHOW_RPC ].freeze
  CLINIC_APPOINTMENT_FILE = "44.003"
  CLINIC_LIST_FIELDS = "@;.01I"
  CLINIC_LIST_MAX = "50"
  CLINIC_GETS_FIELDS = ".01;309;302"
  LISTER_MAX = "500"
  # Clinic hours, each quarter-hour, so a later run the same day is not stuck
  # on the four times an earlier run already booked.
  CLINIC_HOURS = [ 9, 10, 11, 13 ].freeze
  QUARTER_MINUTES = [ 0, 15, 30, 45 ].freeze
  MAX_BOOK_ATTEMPTS = 40

  def self.run
    driver = new
    driver.execute
    driver.document
  end

  def initialize
    @out = {
      "client" => "rpms-rpc RpmsRpc::CiaClient",
      "client_version" => (RpmsRpc.const_defined?(:VERSION) ? RpmsRpc::VERSION : "unversioned"),
      "captures" => {}
    }
    @notes = []
    @setup_access = nil
    @recorder = nil
    @booked_times = []
    @session_duz = {}
  end

  def execute
    guard!
    open_client
    RpmsRpc.with_client(@recorder) { scenario }
  rescue StandardError => e
    @out["error"] = safe_error(e)
  ensure
    finish_incomplete
    close_client
  end

  def document
    export_value(@out)
  rescue StandardError => e
    { "error" => safe_error(e), "captures" => {} }
  end

  private

  def scenario
    @setup_access = sign_on_setup
    provision
    @candidates = open_weekday_times(server_now).each
    bookings = Array.new(3) { |index| book_open_slot(capture: index.zero?) }
    @out["captures"][ADD_RPC] = bookings[0][:payload]
    sign_on_pilot
    # One attempt at a time this run has not used. The refusal is the evidence.
    attach_probe(probe_add(next_candidate))
    check_in(bookings[0])
    cancel_booking(bookings[1])
    mark_missed(bookings[2])
  end

  def guard!
    problems = []
    problems << "LIVE_DISPOSABLE must be 1" unless ENV["LIVE_DISPOSABLE"] == "1"
    unless LOOPBACK_HOSTS.include?(ENV["BROKER_HOST"].to_s.strip)
      problems << "BROKER_HOST must be loopback (127.0.0.1, localhost, or ::1)"
    end
    problems << "RPMS_ACCESS must be a synthetic persona" unless SYNTHETIC_PERSONAS.include?(setup_access_from_env)
    problems << "RPMS_VERIFY is unset" if ENV["RPMS_VERIFY"].to_s.strip.empty?
    raise problems.join("; ") if problems.any?
  end

  def setup_access_from_env
    access = ENV["RPMS_ACCESS"]
    access.nil? || access.empty? ? "SYS123" : access
  end

  def open_client
    port = Integer(broker_port, exception: false)
    raise "BROKER_PORT is not a port number" unless port.is_a?(Integer) && port.positive?

    broker = RpmsRpc::CiaClient.new(host: ENV["BROKER_HOST"].to_s.strip, port: port, timeout: 30)
    @recorder = RpmsRpc::WireCapture::RecordingClient.new(broker)
    @recorder.connect
  end

  def broker_port
    text = ENV["BROKER_PORT"].to_s.strip
    text.empty? ? "9100" : text
  end

  def close_client
    @recorder&.disconnect
  rescue StandardError
    nil
  end

  def sign_on_setup
    access = setup_access_from_env
    verify = ENV["RPMS_VERIFY"]
    raise "RPMS_VERIFY is unset" if verify.nil? || verify.strip.empty?

    @recorder.authenticate(access, verify)
    remember_duz(access)
    access
  end

  # PROV123 comes from CiaClient's development fallback. Clearing the access
  # and verify env names that #authenticate reads keeps an exported setup pair
  # from shadowing that fallback. The values are discarded, not printed.
  def sign_on_pilot
    raise "PROV123 sign-on requires the development credential fallback" unless ENV["VISTA_RPC_ENV"] == "development"

    ENV.delete("RPMS_ACCESS_CODE")
    ENV.delete("RPMS_VERIFY_CODE")
    @recorder.disconnect
    @recorder.connect
    @recorder.authenticate
    remember_duz(PILOT_PERSONA)
  end

  def remember_duz(persona)
    key = persona.to_s
    raise "signed-on persona is not synthetic" unless SYNTHETIC_PERSONAS.include?(key)

    @session_duz[key] = positive_integer_duz(@recorder.duz)
    setup = @out["setup"]
    setup["duz"] = @session_duz.dup if setup.is_a?(Hash)
  end

  def positive_integer_duz(value)
    return value if value.is_a?(Integer) && value.positive?

    text = value.to_s
    raise "session DUZ is not a positive integer" unless text.match?(/\A[1-9]\d*\z/)

    Integer(text, 10)
  end

  def hospital_location_id
    text = @out.dig("setup", "hospital_location_id").to_s.strip
    raise "setup has no hospital location" if text.empty?

    text
  end

  def provision
    resource = find_or_create_resource
    @notes.concat(ensure_file_room_printers)
    @out["setup"] = {
      "resource_ien" => resource[:id],
      "hospital_location_id" => resource[:hospital_location_id],
      "duz" => @session_duz.dup,
      "notes" => @notes.join("; ")
    }
  end

  def find_or_create_resource
    existing = resource_row
    if existing
      @notes << "BSDX RESOURCE #{RESOURCE_NAME} already present (ien #{existing[:id]}, " \
                "hospital location #{existing[:hospital_location_id]})"
    else
      create_resource
      existing = resource_row
      raise "BSDX RESOURCE #{RESOURCE_NAME} is not in Scheduling.resources after create" unless existing
      unless existing[:hospital_location_id].to_s == HOSPITAL_LOCATION_ID
        raise "created #{RESOURCE_NAME} hospital location is #{existing[:hospital_location_id]}, " \
              "not #{HOSPITAL_LOCATION_ID}"
      end
      @notes << "created BSDX RESOURCE #{RESOURCE_NAME} on hospital location #{HOSPITAL_LOCATION_ID} " \
                "(ien #{existing[:id]})"
    end
    raise "Scheduling.resources returned no ien for #{RESOURCE_NAME}" unless existing[:id].to_i.positive?
    unless existing[:hospital_location_id].to_i.positive?
      raise "Scheduling.resources returned no hospital location for #{RESOURCE_NAME}"
    end

    existing
  end

  def resource_row
    rows = RpmsRpc::Scheduling.resources
    raise "Scheduling.resources returned no reply" if rows.nil?

    rows.find { |row| row[:name].to_s.strip == RESOURCE_NAME }
  end

  def create_resource
    reply = @recorder.with_context(RpmsRpc::Scheduling::CONTEXT) do
      @recorder.call_rpc("BSDX ADD/EDIT RESOURCE", RESOURCE_RPC_ARG)
    end
    lines = Array(reply)
    data_row = lines.find { |line| line.to_s.match?(/\A[1-9]\d*\^/) }
    refused = lines.any? { |line| line.to_s.match?(/BSDX14:/i) } || data_row.nil?
    pieces = data_row.to_s.split("^", -1)
    return if !refused && pieces[0].to_i.positive? && pieces[1].to_s.empty?

    raise "BSDX ADD/EDIT RESOURCE refused #{RESOURCE_NAME}: #{refusal_text(lines)}"
  end

  def ensure_file_room_printers
    null_ien = null_device_ien
    listed = ddr_list(PARAMETER_FILE, "@;.01I;.05I")
    raise "no BSD PARAMETERS entries to set a file room printer on" if listed[:entries].empty?

    missing = listed[:entries].select { |entry| entry[:pieces].to_a[1].to_s.split(";").first.to_s.strip.empty? }
    return [ "file room printer already set on every BSD PARAMETERS entry" ] if missing.empty?

    missing.map { |entry| set_file_room_printer(entry[:ien], null_ien) }
  end

  def set_file_room_printer(param_ien, null_ien)
    rows = [ { file: PARAMETER_FILE, field: ".05", iens: "#{param_ien},", value: null_ien } ]
    got = in_ddr { RpmsRpc::DdrFileman.filer(mode: "EDIT", rows: rows) }
    return "set file room printer on BSD PARAMETERS #{param_ien} to #{NULL_DEVICE} device #{null_ien}" if got.is_a?(Hash) && got[:success]

    detail = Array(got.is_a?(Hash) ? got[:errors] : nil).map { |item| plain(item) }.reject(&:empty?).join(" | ")
    suffix = detail.empty? ? "" : ": #{redact(detail[0, 200])}"
    raise "DDR FILER on #{PARAMETER_FILE} #{param_ien} .05 was not accepted#{suffix}"
  end

  def null_device_ien
    listed = ddr_list(DEVICE_FILE, "@;.01")
    entry = listed[:entries].find { |row| row[:pieces].to_a[0].to_s.split(";").first == NULL_DEVICE }
    raise "no #{DEVICE_FILE} device named #{NULL_DEVICE}" unless entry

    ien = entry[:ien].to_s
    raise "no ien for device #{NULL_DEVICE}" if ien.empty? || ien == "0"

    ien
  end

  def ddr_list(file, fields)
    listed = in_ddr { RpmsRpc::DdrFileman.lister(file: file, fields: fields, flags: "IP", max: LISTER_MAX) }
    raise "DDR LISTER on #{file} gave no reply" if listed.nil?
    raise "DDR LISTER on #{file} errored" if listed[:error]
    raise "DDR LISTER on #{file} was not complete" if listed[:more]

    listed
  end

  def in_ddr(&block)
    @recorder.with_context(RpmsRpc::CiaClient::SIGNON_CONTEXT, &block)
  end

  # Take the next unused candidate. A setup-persona refusal is not a capture
  # and is not the ADD write: only the accepted booking's calls are kept.
  def book_open_slot(capture:)
    MAX_BOOK_ATTEMPTS.times do
      booking = book(next_candidate, capture: capture)
      if booking[:id]
        @booked_times << booking[:start_time]
        return booking
      end
      return unbooked(capture, booking[:error]) unless booking[:refused]
    end
    unbooked(capture, "add_appointment refused #{MAX_BOOK_ATTEMPTS} candidates")
  end

  def unbooked(capture, message)
    text = message.to_s.empty? ? "add_appointment was not accepted" : message
    payload = { "signed_on_as" => @setup_access, "error" => text } if capture
    { id: nil, start_fm: nil, payload: payload }
  end

  def next_candidate
    slot = @candidates.next
    slot = @candidates.next while overlaps_booked?(slot)
    slot
  rescue StopIteration
    raise "no unused weekday candidates left in the 3-to-8-week window"
  end

  # A 30-minute appointment covers later quarter-hours, and the minute it
  # ends. Do not hand either to a later booking or to the PROV123 probe.
  def overlaps_booked?(slot)
    slot_end = slot + (LENGTH_MINUTES * 60)
    @booked_times.any? do |start|
      booked_end = start + (LENGTH_MINUTES * 60)
      slot <= booked_end && slot_end >= start
    end
  end

  def book(start_time, capture:)
    start_fm = RpmsRpc::FilemanDateParser.to_fileman(start_time)
    end_fm = RpmsRpc::FilemanDateParser.to_fileman(start_time + (LENGTH_MINUTES * 60))
    kwargs = booking_kwargs(start_fm, end_fm)
    held = {}
    calls, error = with_recording do
      result = RpmsRpc::Scheduling.add_appointment(**kwargs.transform_keys(&:to_sym))
      held[:refused] = result.is_a?(Hash) && result[:success] == false
      held[:id] = booked_id(result)
      read_appointment(held[:id], start_fm)
    end
    payload = if capture && held[:id]
                build_payload(signed_on_as: @setup_access, method: "add_appointment", args: [], kwargs: kwargs,
                              rpc: ADD_RPC, calls: calls, error: error)
    end
    { id: held[:id], start_time: start_time, start_fm: start_fm, payload: payload,
      refused: held[:refused] && held[:id].nil?, error: error }
  end

  # nil and { success: false } refuse the booking kept as the ADD capture.
  # A false success while searching for an open time is retried by the caller.
  def booked_id(result)
    require_accepted_write!(result, "add_appointment")
    id = result[:appointment_id].to_i
    raise "add_appointment was refused#{failure_detail(result)}" unless id.positive?

    id
  end

  def require_accepted_write!(result, method_name)
    return if result.is_a?(Hash) && result[:success] == true

    raise "#{method_name} was refused#{failure_detail(result)}"
  end

  def booking_kwargs(start_fm, end_fm)
    {
      "patient_dfn" => PATIENT_DFN,
      "resource" => RESOURCE_NAME,
      "start_time" => start_fm,
      "end_time" => end_fm,
      "length_minutes" => LENGTH_MINUTES
    }
  end

  def probe_add(start_time)
    start_fm = RpmsRpc::FilemanDateParser.to_fileman(start_time)
    end_fm = RpmsRpc::FilemanDateParser.to_fileman(start_time + (LENGTH_MINUTES * 60))
    calls, error = with_recording do
      RpmsRpc::Scheduling.add_appointment(**booking_kwargs(start_fm, end_fm).transform_keys(&:to_sym))
    end
    write = calls.find { |call| call[:rpc] == ADD_RPC }
    if write.nil? || !write[:inputs].is_a?(Array)
      return { "error" => error || "no #{ADD_RPC} call recorded for the persona probe" }
    end

    { "signed_on_as" => PILOT_PERSONA, "inputs" => export_value(write[:inputs]), "raw" => export_value(write[:raw]) }
  rescue StandardError => e
    { "error" => safe_error(e) }
  end

  def attach_probe(probe)
    capture = @out["captures"][ADD_RPC]
    unless capture.is_a?(Hash)
      @out["captures"][ADD_RPC] = { "error" => probe["error"] || "ADD capture missing" }
      return
    end
    if probe["error"]
      capture["error"] = [ capture["error"], probe["error"] ].compact.reject { |item| item.to_s.empty? }.join("; ")
    else
      capture["persona_probe"] = probe
    end
  end

  def check_in(booking)
    capture_step(CHECKIN_RPC) do
      unless booking && booking[:id]
        record_missing(CHECKIN_RPC, "no appointment to check in")
        next
      end
      checkin_fm = RpmsRpc::FilemanDateParser.to_fileman(one_minute_before(server_now))
      args = [ booking[:id] ]
      kwargs = { "checkin_time" => checkin_fm }
      record_mutation(CHECKIN_RPC, "checkin_appointment", booking, args, kwargs, clinic: hospital_location_id) do
        RpmsRpc::Scheduling.checkin_appointment(*args, **kwargs.transform_keys(&:to_sym))
      end
    end
  end

  def cancel_booking(booking)
    capture_step(CANCEL_RPC) do
      unless booking && booking[:id]
        record_missing(CANCEL_RPC, "no appointment to cancel")
        next
      end
      args = [ booking[:id] ]
      kwargs = { "reason" => CANCEL_REASON, "type" => CANCEL_TYPE, "note" => CANCEL_NOTE }
      record_mutation(CANCEL_RPC, "cancel_appointment", booking, args, kwargs) do
        RpmsRpc::Scheduling.cancel_appointment(*args, **kwargs.transform_keys(&:to_sym))
      end
    end
  end

  def mark_missed(booking)
    capture_step(NOSHOW_RPC) do
      unless booking && booking[:id]
        record_missing(NOSHOW_RPC, "no appointment to mark no-show")
        next
      end
      args = [ booking[:id] ]
      record_mutation(NOSHOW_RPC, "mark_no_show", booking, args, {}) do
        RpmsRpc::Scheduling.mark_no_show(*args)
      end
    end
  end

  # The same DDR GETS calls immediately before the write and after it.
  # nil or { success: false } from the API is a step error on this capture.
  def record_mutation(rpc, method_name, booking, args, kwargs, clinic: nil)
    calls, error = with_recording do
      read_effect(booking[:id], booking[:start_fm], clinic: clinic)
      result = yield
      require_accepted_write!(result, method_name)
      read_effect(booking[:id], booking[:start_fm], clinic: clinic)
    end
    @out["captures"][rpc] = build_payload(
      signed_on_as: PILOT_PERSONA, method: method_name, args: args, kwargs: kwargs,
      rpc: rpc, calls: calls, error: error
    )
  end

  def capture_step(rpc)
    yield
  rescue StandardError => e
    @out["captures"][rpc] ||= { "signed_on_as" => PILOT_PERSONA, "error" => safe_error(e) }
  end

  def record_missing(rpc, message)
    @out["captures"][rpc] = { "signed_on_as" => PILOT_PERSONA, "error" => message }
  end

  def read_appointment(appointment_ien, start_fm)
    iens = "#{canonical_fileman_datetime(start_fm)},#{PATIENT_DFN},"
    in_ddr do
      RpmsRpc::DdrFileman.gets_entry(file: APPOINTMENT_FILE, iens: "#{appointment_ien},",
                                     fields: APPOINTMENT_FIELDS, flags: "I")
      RpmsRpc::DdrFileman.gets_entry(file: PATIENT_APPOINTMENT_FILE, iens: iens,
                                     fields: PATIENT_APPOINTMENT_FIELDS, flags: "I")
    end
  end

  def read_effect(appointment_ien, start_fm, clinic: nil)
    read_appointment(appointment_ien, start_fm)
    read_clinic_checkin(start_fm, clinic) unless clinic.nil?
  end

  # HOSPITAL LOCATION's appointment patients (#44.003) for this start and the
  # resource's clinic, under CIAV VUECENTRIC (in_ddr). The lister only finds
  # the sub-entry whose .01 is the patient; the GETS call is the evidence.
  def read_clinic_checkin(start_fm, clinic)
    canonical = canonical_fileman_datetime(start_fm)
    list_iens = ",#{canonical},#{clinic},"
    listed = in_ddr do
      RpmsRpc::DdrFileman.lister(
        file: CLINIC_APPOINTMENT_FILE, iens: list_iens, fields: CLINIC_LIST_FIELDS,
        flags: "IP", max: CLINIC_LIST_MAX
      )
    end
    raise "DDR LISTER on #{CLINIC_APPOINTMENT_FILE} gave no reply" if listed.nil?
    raise "DDR LISTER on #{CLINIC_APPOINTMENT_FILE} errored" if listed[:error]
    raise "DDR LISTER on #{CLINIC_APPOINTMENT_FILE} was not complete" if listed[:more]

    matches = Array(listed[:entries]).select { |entry| clinic_patient?(entry) }
    unless matches.size == 1
      raise "HOSPITAL LOCATION #{CLINIC_APPOINTMENT_FILE} #{list_iens} has #{matches.size} entries for the patient"
    end

    sub_ien = matches.first[:ien].to_s
    raise "HOSPITAL LOCATION entry has no sub-ien" if sub_ien.empty? || sub_ien == "0"

    in_ddr do
      RpmsRpc::DdrFileman.gets_entry(
        file: CLINIC_APPOINTMENT_FILE, iens: "#{sub_ien},#{canonical},#{clinic},",
        fields: CLINIC_GETS_FIELDS, flags: "I"
      )
    end
  end

  def clinic_patient?(entry)
    entry[:pieces].to_a.first.to_s.split(";", 2).first.to_s.strip == PATIENT_DFN.to_s
  end

  def with_recording
    mark = @recorder.rpc_calls.size
    error = nil
    begin
      yield
    rescue StandardError => e
      error = safe_error(e)
    end
    [ @recorder.rpc_calls[mark..], error ]
  end

  def build_payload(signed_on_as:, method:, args:, kwargs:, rpc:, calls:, error:)
    write = calls.find { |call| call[:rpc] == rpc }
    before, after = gets_around_write(calls, rpc)
    problems = payload_problems(write, before, after, error, rpc)
    payload = {
      "signed_on_as" => signed_on_as,
      "api_call" => { "method" => method, "args" => args, "kwargs" => kwargs }
    }
    if write && write[:inputs].is_a?(Array)
      payload["inputs"] = export_value(write[:inputs])
      payload["raw"] = export_value(write[:raw])
    end
    expect = expected_gets_count(rpc)
    if CAUSATION_RPCS.include?(rpc) && complete_gets?(before, expect)
      payload["read_before"] = before.map { |call| export_recorded(call) }
    end
    payload["read_back"] = after.map { |call| export_recorded(call) } if complete_gets?(after, expect)
    payload["error"] = problems.join("; ") if problems.any?
    payload
  rescue StandardError => e
    { "signed_on_as" => signed_on_as, "error" => safe_error(e) }
  end

  def payload_problems(write, before, after, error, rpc)
    problems = []
    problems << error if error.is_a?(String) && !error.empty?
    problems << "no #{rpc} call recorded" if write.nil?
    problems << "recorded write inputs were not a parameter list" if write && !write[:inputs].is_a?(Array)
    expect = expected_gets_count(rpc)
    if CAUSATION_RPCS.include?(rpc) && !complete_gets?(before, expect)
      problems << "read-before did not record #{expect} DDR GETS ENTRY DATA calls"
    end
    unless complete_gets?(after, expect)
      problems << "read-back did not record #{expect} DDR GETS ENTRY DATA calls"
    end
    problems
  end

  def expected_gets_count(rpc)
    rpc == CHECKIN_RPC ? READ_BACK_COUNT + 1 : READ_BACK_COUNT
  end

  def complete_gets?(calls, expect)
    calls.size == expect && calls.all? { |call| call[:inputs].is_a?(Hash) }
  end

  # GETS calls before the write are read_before; GETS calls after it are
  # read_back. DDR LISTER finds the #44.003 sub-entry and is not evidence.
  def gets_around_write(calls, rpc)
    write_at = calls.index { |call| call[:rpc] == rpc }
    return [ [], evidence_gets(calls) ] if write_at.nil?

    [ evidence_gets(calls[0...write_at]), evidence_gets(calls[(write_at + 1)..]) ]
  end

  def evidence_gets(calls)
    Array(calls).select { |call| call[:rpc] == DDR_RPC }
  end

  def export_recorded(call)
    { "rpc" => call[:rpc].to_s, "inputs" => export_value(call[:inputs]), "raw" => export_value(call[:raw]) }
  end

  def server_now
    polled = @recorder.poll
    time = polled[:server_time]
    raise "broker poll returned no server time" if time.nil?

    time
  end

  # One minute before the server's current minute, at minute precision, so
  # CHECKIN^BSDX25's future-time clamp does not rewrite the value it stores.
  def one_minute_before(time)
    minute = Time.new(time.year, time.month, time.day, time.hour, time.min, 0, time.utc_offset)
    shifted = minute - 60
    Time.new(shifted.year, shifted.month, shifted.day, shifted.hour, shifted.min, 0, shifted.utc_offset)
  end

  # FileMan drops trailing zeros of a time when it is used as an IENS. A
  # trailing zero ("3270107.0930") is not the stored subscript ("3270107.093").
  def canonical_fileman_datetime(value)
    text = value.to_s
    return text unless text.include?(".")

    date, fraction = text.split(".", 2)
    fraction = fraction.sub(/0+\z/, "")
    fraction.empty? ? date : "#{date}.#{fraction}"
  end

  # Weekday clinic times, inclusive, from 3 weeks out through 8 weeks out,
  # at several hours and each quarter-hour. Callers take the next candidate
  # this run has not used.
  def open_weekday_times(origin_time)
    origin = Date.new(origin_time.year, origin_time.month, origin_time.day)
    offset = origin_time.utc_offset
    days = ((origin + 21)..(origin + 56)).reject { |day| day.saturday? || day.sunday? }
    raise "no open weekdays in the 3-to-8-week window" if days.empty?

    days.flat_map { |day| times_on(day, offset) }
  end

  def times_on(day, offset)
    CLINIC_HOURS.product(QUARTER_MINUTES).map do |hour, minute|
      Time.new(day.year, day.month, day.day, hour, minute, 0, offset)
    end
  end

  def finish_incomplete
    add = @out["captures"][ADD_RPC]
    if add.is_a?(Hash) && !probe_recorded?(add) && add["error"].to_s.empty?
      add["error"] = @out["error"].to_s.empty? ? "persona_probe was not recorded" : @out["error"]
    end
    reason = @out["error"].to_s
    reason = "not run" if reason.empty?
    WRITE_RPCS.each { |rpc| @out["captures"][rpc] ||= { "error" => reason } }
  end

  def probe_recorded?(capture)
    probe = capture["persona_probe"]
    probe.is_a?(Hash) && !probe["raw"].to_s.empty?
  end

  def failure_detail(result)
    return "" unless result.is_a?(Hash)

    text = plain(result[:error])[0, 200]
    return "" if text.to_s.empty?

    ": #{redact(text)}"
  end

  def refusal_text(lines)
    text = lines.map { |line| plain(line) }.reject(&:empty?).join(" | ")
    redact(text[0, 200].to_s)
  end

  def safe_error(error)
    redact("#{error.class}: #{plain(error.message)}")
  end

  def plain(text)
    text.to_s.gsub(/[^\x20-\x7e]/, " ").squeeze(" ").strip
  end

  def redact(text)
    credential_secrets.reduce(text.dup) { |scrubbed, secret| scrubbed.gsub(secret, "[redacted]") }
  end

  def credential_secrets
    %w[RPMS_VERIFY RPMS_VERIFY_CODE PROV123_VERIFY SYS123_VERIFY].filter_map { |key| ENV[key] }
      .map(&:to_s).select { |value| value.strip.length >= 4 }.uniq.sort_by(&:length).reverse
  end

  def export_value(value)
    case value
    when Hash
      value.each_with_object({}) { |(key, item), out| out[export_value(key).to_s] = export_value(item) }
    when Array
      value.map { |item| export_value(item) }
    when String
      utf8_bytes(value)
    when Integer, TrueClass, FalseClass, NilClass
      value
    else
      raise "captured value #{value.class} is not JSON data"
    end
  end

  def utf8_bytes(str)
    text = str.dup
    text.force_encoding(Encoding::UTF_8)
    raise "captured bytes are not valid UTF-8" unless text.valid_encoding?

    text
  end
end

puts JSON.generate(WriteCaptureDriver.run)
