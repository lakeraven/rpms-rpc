# frozen_string_literal: true

# Live run of the rpms-rpc READ API against ONE backend, for `rake rpc:live` (rpms-rpc#270).
# Ported from cloud-rpms scripts/shared/rpms-rpc-live.rb (the application-level driver).
#
# READ-ONLY by construction: the catalogue below names only methods that list, find or
# summarize. Nothing that files, locks, signs, sends or registers is called.
#
# Verdicts come from the WIRE, not from the API's return value. CiaClient#call_rpc flattens a
# broker error reply ($C(1)+text) to printable text instead of raising (#195), so an API method
# can return a non-nil "result" that is really an error. Each raw reply is classified by its
# CIA flag byte: \x00 -> data, \x01 -> broker error, no flag -> no data (SNDEOD).
#
# One broker connection at a time; a dropped or desynced session is closed and signed on again.
# The access and verify codes are read from the environment and never written anywhere.
#
# Env: BACKEND (evidence label), BROKER_HOST, BROKER_PORT, RPMS_ACCESS, RPMS_VERIFY,
#      RPMS_CONTEXT (optional option to bind), CASE_TIMEOUT (default 45 s), DFN (optional),
#      EVIDENCE (path of <rpms-diffs>/rpc-coverage/live/<BACKEND>.json to merge into)
require "json"
require "date"
require "time"
require "timeout"

LIB = File.expand_path("../../lib", __dir__)
$LOAD_PATH.unshift(LIB)
require "rpms_rpc/version"
require "rpms_rpc/cia_client"
require "rpms_rpc/mappings"
Dir[File.join(LIB, "rpms_rpc/api/*.rb")].each { |f| require f }
require_relative "rpc_coverage"

BACKEND = ENV.fetch("BACKEND")
HOST = ENV.fetch("BROKER_HOST", "127.0.0.1")
PORT = Integer(ENV.fetch("BROKER_PORT"))
ACCESS = ENV.fetch("RPMS_ACCESS")
VERIFY = ENV.fetch("RPMS_VERIFY")
EVIDENCE = ENV.fetch("EVIDENCE")
CASE_TIMEOUT = Integer(ENV.fetch("CASE_TIMEOUT", "45"))
# Context option to bind after sign-on. Unset = stay on the option the client signed on under
# (RpmsRpc::CiaClient::SIGNON_CONTEXT). A user holding XUPROGMODE bypasses the context check
# either way (CIANBACT), so only a non-programmer run measures context gating (#263).
CONTEXT = ENV["RPMS_CONTEXT"].to_s.empty? ? nil : ENV["RPMS_CONTEXT"]

# Record every wire call the API makes, with the reply's CIA flag.
module WireTrace
  def self.log = (@log ||= [])

  def self.classify(raw)
    rest = raw.to_s.b.byteslice(1..) || "".b
    case rest.getbyte(0)
    when 0x00 then [ :data, (rest.bytesize - 1) ]
    when 0x01 then [ :error, rest.byteslice(1..).to_s.gsub(/[^\x20-\x7e]/, " ").strip[0, 160] ]
    else [ :no_data, 0 ]
    end
  end

  def call_rpc_raw(rpc_name, *params)
    raw = super
    kind, detail = WireTrace.classify(raw)
    WireTrace.log << { rpc: rpc_name, reply: kind, detail: detail }
    raw
  rescue RpmsRpc::Client::ConnectionError, IOError, SystemCallError => e
    WireTrace.log << { rpc: rpc_name, reply: :transport_error, detail: "#{e.class}: #{e.message}"[0, 160] }
    raise
  end

  def call_rpc_global_array(rpc_name, *params)
    raw = super
    kind, detail = WireTrace.classify(raw)
    WireTrace.log << { rpc: rpc_name, reply: kind, detail: detail }
    raw
  end
end
RpmsRpc::CiaClient.prepend(WireTrace)

# Back-to-back connections through an SSM tunnel are flaky (the broker side closes the
# first frame of a fresh socket now and then), so a sign-on is retried with backoff.
def sign_on(tries: 5)
  attempt = 0
  begin
    attempt += 1
    c = RpmsRpc::CiaClient.new(host: HOST, port: PORT, timeout: 30)
    c.connect
    c.authenticate(ACCESS, VERIFY)
    c.create_context(CONTEXT) if CONTEXT
    RpmsRpc.configure { |cfg| cfg.client = c }
    $signons = ($signons || 0) + 1
    c
  rescue RpmsRpc::Client::ConnectionError, IOError, SystemCallError
    raise if attempt >= tries

    sleep(2 * attempt)
    retry
  end
end

def alive?(c)
  c.connected? && c.authenticated?
end

# Bytes still on the socket after a call has returned mean the client stopped reading that
# reply early. The CIA reply has no length, only the EOD byte, and a reply that EMBEDS \x1e
# (a global array: BSDX scheduling, found 2026-09-23, rpms-rpc#254) leaves the tail unread.
# The next call then reads that tail as its reply, and every later reply on the session is the
# previous call's. So: look after every case, name the case, and reconnect.
def leftover_bytes(c, wait: 0.3)
  sock = c.instance_variable_get(:@socket)
  return "" unless sock
  buf = +""
  deadline = Time.now + wait
  while Time.now < deadline
    begin
      buf << sock.read_nonblock(65_536)
    rescue IO::WaitReadable
      sleep 0.05
    rescue IOError, SystemCallError # EOFError is an IOError
      break
    end
  end
  buf
end

def shape(v)
  case v
  when nil then "nil"
  when Array then "Array[#{v.size}]"
  when Hash then "Hash{#{v.size}}"
  when String then "String(#{v.size})"
  when true, false then v.to_s
  else v.class.name
  end
end

def first_ien(list, *keys)
  Array(list).each do |row|
    next unless row.is_a?(Hash)
    keys.each { |k| return row[k].to_s if row[k].to_s =~ /\A\d+(\.\d+)?\z/ && row[k].to_f.positive? }
  end
  nil
end

client = sign_on
duz = client.duz.to_s
ctx = { duz: duz }
results = []
today = Date.today
year_ago = today - 365

run = lambda do |name, &blk|
  client = sign_on unless alive?(client)
  WireTrace.log.clear
  started = Time.now
  value = nil
  error = nil
  begin
    Timeout.timeout(CASE_TIMEOUT) { value = blk.call }
  rescue Exception => e # rubocop:disable Lint/RescueException -- Timeout::Error included; one case must not end the run
    error = "#{e.class}: #{e.message}"[0, 200]
  end
  wire = WireTrace.log.dup
  dropped = !alive?(client)
  stray = dropped ? "" : leftover_bytes(client)
  verdict =
    if !stray.empty? then "stream-desync"
    elsif wire.any? { |w| w[:reply] == :transport_error } || dropped then "session-dropped"
    elsif wire.empty? then (error ? "raised-before-wire" : "no-rpc")
    elsif wire.any? { |w| w[:reply] == :error } then "broker-error"
    elsif error then "client-error"
    elsif wire.all? { |w| w[:reply] == :no_data } then "no-data"
    else "ok"
    end
  row = { case: name, verdict: verdict, result: shape(value), error: error,
         secs: (Time.now - started).round(2), wire: wire }
  unless stray.empty?
    row[:stray_bytes] = stray.bytesize
    error = "#{stray.bytesize} byte(s) left unread on the socket; reconnecting"
    row[:error] = error
    begin
      client.disconnect
    rescue StandardError
      nil
    end
  end
  results << row
  printf("%-16s %-52s %-24s %s\n", verdict, name, row[:result],
         (error || wire.find { |w| w[:reply] == :error }&.dig(:detail)).to_s[0, 100])
  client = sign_on unless alive?(client)
  value
end

puts "context: #{CONTEXT || "#{RpmsRpc::CiaClient::SIGNON_CONTEXT} (sign-on)"}"
puts "signed on: DUZ=#{duz} user=#{client.respond_to?(:signon_user) ? client.signon_user : '?'}"

# --- discovery: resolve real IENs from the stack before the per-method cases -----------------
pts = run.call("Patient.search(\"A\")") { RpmsRpc::Patient.search("A") }
ctx[:dfn] = ENV["DFN"] || first_ien(pts, :dfn, :ien, :id) || "1"
puts "using DFN=#{ctx[:dfn]}"

visits = run.call("Encounter.for_patient") { RpmsRpc::Encounter.for_patient(ctx[:dfn]) }
ctx[:visit] = first_ien(visits, :visit_ien, :ien, :id)
notes = run.call("ProgressNote.list") { RpmsRpc::ProgressNote.list(ctx[:dfn]) }
ctx[:note] = first_ien(notes, :ien, :note_ien, :id)
orders = run.call("Order.list") { RpmsRpc::Order.list(ctx[:dfn]) }
ctx[:order] = first_ien(orders, :ien, :order_ien, :id)
probs = run.call("Problem.for_patient") { RpmsRpc::Problem.for_patient(ctx[:dfn]) }
ctx[:problem] = first_ien(probs, :ien, :id)
roots = run.call("NoteTemplate.roots") { RpmsRpc::NoteTemplate.roots(duz) }
ctx[:template] = first_ien(roots, :ien, :id)
hlocs = run.call("Scheduling.hospital_locations") { RpmsRpc::Scheduling.hospital_locations }
ctx[:location] = first_ien(hlocs, :ien, :id, :location_ien)
puts "resolved: #{ctx.reject { |k, _| k == :duz }.map { |k, v| "#{k}=#{v || '-'}" }.join(' ')}"

d = ctx[:dfn]
cases = {
  # identity / session
  "Authentication.user_info" => -> { RpmsRpc::Authentication.user_info(duz) },
  "Authentication.user_security_keys" => -> { RpmsRpc::Authentication.user_security_keys(duz) },
  "Session.bootstrap" => -> { RpmsRpc::Session.bootstrap(duz) },
  "Site.current" => -> { RpmsRpc::Site.current(duz) },
  "Site.list" => -> { RpmsRpc::Site.list(duz) },
  "UserManagement.search(\"PROV\")" => -> { RpmsRpc::UserManagement.search("PROV") },
  "UserManagement.find" => -> { RpmsRpc::UserManagement.find(duz) },
  "Practitioner.search(\"PROV\")" => -> { RpmsRpc::Practitioner.search("PROV") },
  "Practitioner.find" => -> { RpmsRpc::Practitioner.find(duz) },
  "Notifications.inbox" => -> { RpmsRpc::Notifications.inbox(duz) },
  "Communication.for_user" => -> { RpmsRpc::Communication.for_user(duz) },
  "Communication.alert_count" => -> { RpmsRpc::Communication.alert_count(duz) },
  "Order.unsigned_for_user" => -> { RpmsRpc::Order.unsigned_for_user(duz) },
  # patient chart
  "Patient.find" => -> { RpmsRpc::Patient.find(d) },
  "Patient.brief_header" => -> { RpmsRpc::Patient.brief_header(d) },
  "Allergy.for_patient" => -> { RpmsRpc::Allergy.for_patient(d) },
  "Allergy.assessment" => -> { RpmsRpc::Allergy.assessment(d) },
  "Vital.for_patient" => -> { RpmsRpc::Vital.for_patient(d) },
  "Medication.for_patient" => -> { RpmsRpc::Medication.for_patient(d) },
  "Lab.for_patient" => -> { RpmsRpc::Lab.for_patient(d) },
  "Lab.reports" => -> { RpmsRpc::Lab.reports(d) },
  "Immunization.for_patient" => -> { RpmsRpc::Immunization.for_patient(d) },
  "Immunization.text_summary" => -> { RpmsRpc::Immunization.text_summary(d) },
  "Radiology.for_patient" => -> { RpmsRpc::Radiology.for_patient(d) },
  "Image.exams_for_patient" => -> { RpmsRpc::Image.exams_for_patient(d) },
  "Procedure.for_patient" => -> { RpmsRpc::Procedure.for_patient(d) },
  "Referral.for_patient" => -> { RpmsRpc::Referral.for_patient(d) },
  "CarePlan.for_patient" => -> { RpmsRpc::CarePlan.for_patient(d) },
  "CareTeam.for_patient" => -> { RpmsRpc::CareTeam.for_patient(d) },
  "Goal.for_patient" => -> { RpmsRpc::Goal.for_patient(d) },
  "Device.for_patient" => -> { RpmsRpc::Device.for_patient(d) },
  "Communication.for_patient" => -> { RpmsRpc::Communication.for_patient(d) },
  "Eligibility.for_patient" => -> { RpmsRpc::Eligibility.for_patient(d) },
  "Tribal.enrollment" => -> { RpmsRpc::Tribal.enrollment(d) },
  "Tribal.eligibility" => -> { RpmsRpc::Tribal.eligibility(d) },
  "Adt.admissions" => -> { RpmsRpc::Adt.admissions(d) },
  "Adt.current_location" => -> { RpmsRpc::Adt.current_location(d) },
  "Phr.enrollment_status" => -> { RpmsRpc::Phr.enrollment_status(d) },
  "Phr.counts" => -> { RpmsRpc::Phr.counts(d) },
  "Order.sheets_for_patient" => -> { RpmsRpc::Order.sheets_for_patient(d) },
  "Problem.filter(:core)" => -> { RpmsRpc::Problem.filter(d, scope: :core) },
  "Problem.provider_list" => -> { RpmsRpc::Problem.provider_list(d) },
  "HealthSummary.types" => -> { RpmsRpc::HealthSummary.types },
  "HealthSummary.for_patient" => -> { RpmsRpc::HealthSummary.for_patient(d) },
  "HealthSummary.clinical_reminders" => -> { RpmsRpc::HealthSummary.clinical_reminders(d) },
  "HealthSummary.health_maintenance" => -> { RpmsRpc::HealthSummary.health_maintenance(d) },
  "HealthSummary.flowsheet_definitions" => -> { RpmsRpc::HealthSummary.flowsheet_definitions },
  "BehavioralHealth.visits" => -> { RpmsRpc::BehavioralHealth.visits(d, from: year_ago, to: today) },
  "BehavioralHealth.treatment_plans" => -> { RpmsRpc::BehavioralHealth.treatment_plans(d, from: year_ago, to: today) },
  "BehavioralHealth.suicide_forms" => -> { RpmsRpc::BehavioralHealth.suicide_forms(d, from: year_ago, to: today) },
  # reference data
  "Eligibility.codes" => -> { RpmsRpc::Eligibility.codes },
  "Symptom.defaults" => -> { RpmsRpc::Symptom.defaults },
  "Symptom.search(\"COUGH\")" => -> { RpmsRpc::Symptom.search("COUGH") },
  "Problem.lex_search(\"DIABETES\")" => -> { RpmsRpc::Problem.lex_search("DIABETES") },
  "ImmunizationRefusal.reasons" => -> { RpmsRpc::ImmunizationRefusal.reasons },
  "VaccineLot.for_facility" => -> { RpmsRpc::VaccineLot.for_facility },
  "Tribal.tribes" => -> { RpmsRpc::Tribal.tribes },
  "Order.all_sheets" => -> { RpmsRpc::Order.all_sheets },
  "Scheduling.clinic_setup" => -> { RpmsRpc::Scheduling.clinic_setup },
  "Scheduling.all_appointments(30d)" => -> { RpmsRpc::Scheduling.all_appointments(start_date: today - 30, end_date: today + 30) },
  "UserManagement.list_all_keys" => -> { RpmsRpc::UserManagement.list_all_keys },
  "ChsBudget.budget_summary" => -> { RpmsRpc::ChsBudget.budget_summary },
  "Vendor.search(\"A\")" => -> { RpmsRpc::Vendor.search(name: "A") },
  "Referral.purposes" => -> { RpmsRpc::Referral.purposes },
  "Referral.health_summary_types" => -> { RpmsRpc::Referral.health_summary_types }
}
cases["Location.find"] = -> { RpmsRpc::Location.find(ctx[:location]) } if ctx[:location]
cases["Vital.template"] = -> { RpmsRpc::Vital.template(ctx[:location]) } if ctx[:location]
cases["Encounter.visit_string"] = -> { RpmsRpc::Encounter.visit_string(ctx[:location], today, "A") } if ctx[:location]
cases["Reminders.for_visit"] = -> { RpmsRpc::Reminders.for_visit(d, ctx[:visit]) } if ctx[:visit]
cases["BehavioralHealth.visit_information"] = -> { RpmsRpc::BehavioralHealth.visit_information(ctx[:visit]) } if ctx[:visit]
cases["ProgressNote.fetch_text"] = -> { RpmsRpc::ProgressNote.fetch_text(ctx[:note]) } if ctx[:note]
cases["Order.result"] = -> { RpmsRpc::Order.result(ctx[:order]) } if ctx[:order]
cases["Problem.details"] = -> { RpmsRpc::Problem.details(ctx[:problem]) } if ctx[:problem]
cases["Problem.audit_history"] = -> { RpmsRpc::Problem.audit_history(ctx[:problem]) } if ctx[:problem]
cases["NoteTemplate.items"] = -> { RpmsRpc::NoteTemplate.items(ctx[:template]) } if ctx[:template]
cases["NoteTemplate.text"] = -> { RpmsRpc::NoteTemplate.text(ctx[:template]) } if ctx[:template]

cases.each { |name, fn| run.call(name) { fn.call } }

begin
  client.disconnect
rescue StandardError
  nil
end

# --- evidence: per RPC, did the backend answer without a broker error? ------------------------
now = Time.now.utc.iso8601
outcomes = {}
results.flat_map { |r| r[:wire] }.each do |w|
  name = w[:rpc].to_s
  ok = %i[data no_data].include?(w[:reply])
  cur = outcomes[name]
  next if cur && cur["outcome"] == "ok"

  outcomes[name] = ok ? { "outcome" => "ok", "last_at" => now } : { "outcome" => "error", "error" => w[:detail].to_s[0, 160], "last_at" => now }
end
tally = results.group_by { |r| r[:verdict] }.transform_values(&:size)
rev = `git -C #{File.expand_path('../..', __dir__)} rev-parse --short HEAD 2>/dev/null`.strip
run_meta = {
  "at" => now, "rpms_rpc" => "#{RpmsRpc::VERSION}#{rev.empty? ? '' : " @ #{rev}"}", "host_label" => BACKEND,
  "context" => CONTEXT || "#{RpmsRpc::CiaClient::SIGNON_CONTEXT} (sign-on)", "cases" => results.size,
  "tally" => tally, "signons" => $signons
}
evidence = RpcCoverage.load_evidence(EVIDENCE, BACKEND)
evidence = RpcCoverage.merge_run(evidence, run_meta, outcomes)
problems = RpcCoverage.evidence_problems(evidence, secrets: [ ACCESS, VERIFY ])
abort("!! refusing to write evidence: #{problems.join('; ')}") unless problems.empty?
File.write(EVIDENCE, JSON.pretty_generate(evidence) + "\n")

puts
puts "cases: #{results.size}  #{tally.sort.map { |k, v| "#{k}=#{v}" }.join('  ')}"
puts "sign-ons: #{$signons} (1 + one per dropped session)"
puts "distinct RPCs sent: #{outcomes.size}  (answered: #{outcomes.count { |_, o| o['outcome'] == 'ok' }}, errored: #{outcomes.count { |_, o| o['outcome'] == 'error' }})"
puts "merged into #{EVIDENCE} (#{evidence['rpcs'].size} RPCs across #{evidence['runs'].size} run(s))"
