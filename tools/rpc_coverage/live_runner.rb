# frozen_string_literal: true

# Live run of the rpms-rpc READ API against ONE backend, for `rake rpc:live` (rpms-rpc#270).
# Ported from cloud-rpms scripts/shared/rpms-rpc-live.rb (the application-level driver).
#
# READ-ONLY by construction: the catalogue below names only methods that list, find or
# summarize. Nothing that files, locks, signs, sends or registers is called.
#
# Verdicts come from the WIRE, not from the API's return value: an API method may rescue or
# reshape what the client raised, so its return value alone cannot say what the broker answered.
# (CiaClient#call_rpc once flattened a broker error reply to text, #195; parse_cia_reply now
# raises on the \x01 flag.) Each raw reply is classified by its CIA flag byte:
# \x00 -> data, \x01 -> broker error, no flag -> no data (SNDEOD).
#
# One broker connection at a time; a dropped or desynced session is closed and signed on again.
# The access and verify codes are read from the environment and never written anywhere.
#
# Env: BACKEND (evidence label), BROKER_HOST, BROKER_PORT,
#      ROLE (the test role the run signs on as, README, Test roles; the run is recorded under it),
#      RPMS_ACCESS, RPMS_VERIFY (optional: the pair, when the target's differs from the role's published one;
#      ROLE=operator needs RPMS_VERIFY),
#      RPMS_CONTEXT (optional option to bind), CASE_TIMEOUT (default 45 s), DFN (optional),
#      EVIDENCE_DIR (<rpms-diffs>/rpc-coverage/live: the run merges into <BACKEND>.<ROLE>.json)
#      or EVIDENCE (an explicit file to merge into),
#      CASES (optional: a file to write one JSON line per case to: the case, its verdict, its error, the role and
#      each RPC it sent with the reply kind; the openrpms release gate builds its per-RPC record from it)
#
# The run is refused, and writes no evidence, unless the account the pair signs on as is the role's
# (its NEW PERSON name) and holds XUPROGMODE exactly when the role's row says so.
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
require_relative "wire_trace"

BACKEND = ENV.fetch("BACKEND")
begin
  ROLE = RpcCoverage.run_role(ENV)
  ACCESS, VERIFY = RpcCoverage.sign_on_pair(ROLE, ENV)
rescue RpcCoverage::Error => e
  abort("!! #{e.message}; no evidence written")
end
HOST = ENV.fetch("BROKER_HOST", "127.0.0.1")
PORT = Integer(ENV.fetch("BROKER_PORT"))
CASE_TIMEOUT = Integer(ENV.fetch("CASE_TIMEOUT", "45"))
# Context option to bind after sign-on. Unset = stay on the option the client signed on under
# (RpmsRpc::CiaClient::SIGNON_CONTEXT). A user holding XUPROGMODE bypasses the context check
# either way (CIANBACT), so only a run as a role other than the operator measures context gating (#263).
CONTEXT = ENV["RPMS_CONTEXT"].to_s.empty? ? nil : ENV["RPMS_CONTEXT"]

WireTrace = RpcCoverage::WireTrace
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
# Who signed on, read before anything is recorded: the account's NEW PERSON name, from sign-on, and
# whether it holds XUPROGMODE. ORWU HASKEY is read as reply LINES: call_rpc's printable() keeps the
# sequence echo, so Authentication.has_security_key? reads "5 1" as not-held over CIA. A dropped
# session is signed on again and asked again rather than read as "not held".
haskey_tries = 0
progmode = begin
  haskey_tries += 1
  RpcCoverage.holds_progmode?(client.call_rpc_lines("ORWU HASKEY", "XUPROGMODE"))
rescue RpmsRpc::Client::ConnectionError, IOError, SystemCallError => e
  abort("!! ORWU HASKEY XUPROGMODE did not answer (#{e.class}); who signed on is unknown, no evidence written") if haskey_tries >= 2
  client = sign_on
  retry
end
if (problem = RpcCoverage.signed_on_problem(ROLE, user: client.signon_user, holds_progmode: progmode))
  abort("!! #{problem}; no evidence written")
end
EVIDENCE = ENV["EVIDENCE"].to_s.empty? ? RpcCoverage.evidence_path(ENV.fetch("EVIDENCE_DIR"), BACKEND, ROLE.name) : ENV["EVIDENCE"]
WireTrace.log.clear
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
  # One case must not end the run: StandardError covers Timeout::Error and every broker/client error,
  # and NotImplementedError (a ScriptError) is what the clients raise for an unsupported path. Interrupt
  # and SystemExit are left alone, so Ctrl-C still stops a live run.
  rescue StandardError, NotImplementedError => e
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

puts "role: #{ROLE.name} (#{ROLE.account}; XUPROGMODE #{progmode ? 'held' : 'not held'})"
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
  "Session.bootstrap" => -> { RpmsRpc::Session.bootstrap(duz) },
  "Site.current" => -> { RpmsRpc::Site.current(duz) },
  "Site.list" => -> { RpmsRpc::Site.list(duz) },
  "UserManagement.search(\"PROV\")" => -> { RpmsRpc::UserManagement.search("PROV") },
  "UserManagement.find" => -> { RpmsRpc::UserManagement.find(duz) },
  "Practitioner.search(\"PROV\")" => -> { RpmsRpc::Practitioner.search("PROV") },
  "Practitioner.find" => -> { RpmsRpc::Practitioner.find(duz) },
  "Notifications.inbox" => -> { RpmsRpc::Notifications.inbox },
  "Order.expired_search_start" => -> { RpmsRpc::Order.expired_search_start },
  # patient chart
  "Patient.find" => -> { RpmsRpc::Patient.find(d) },
  "Patient.brief_header" => -> { RpmsRpc::Patient.brief_header(d) },
  "Allergy.for_patient" => -> { RpmsRpc::Allergy.for_patient(d) },
  "Allergy.assessment" => -> { RpmsRpc::Allergy.assessment(d) },
  "Vital.for_patient" => -> { RpmsRpc::Vital.for_patient(d) },
  "Medication.for_patient" => -> { RpmsRpc::Medication.for_patient(d) },
  "Immunization.text_summary" => -> { RpmsRpc::Immunization.text_summary(d) },
  "Image.exams_for_patient" => -> { RpmsRpc::Image.exams_for_patient(d) },
  "Referral.for_patient" => -> { RpmsRpc::Referral.for_patient(d) },
  "Tribal.enrollment" => -> { RpmsRpc::Tribal.enrollment(d) },
  "Tribal.eligibility" => -> { RpmsRpc::Tribal.eligibility(d) },
  "Adt.admissions" => -> { RpmsRpc::Adt.admissions(d) },
  "Adt.current_location" => -> { RpmsRpc::Adt.current_location(d) },
  "Phr.enrollment_status" => -> { RpmsRpc::Phr.enrollment_status(d) },
  "Phr.counts" => -> { RpmsRpc::Phr.counts(d) },
  "Order.sheets_for_patient" => -> { RpmsRpc::Order.sheets_for_patient(d) },
  "Order.unsigned_for_patient" => -> { RpmsRpc::Order.unsigned_for_patient(d) },
  "Problem.provider_list" => -> { RpmsRpc::Problem.provider_list(d) },
  "HealthSummary.for_patient" => -> { RpmsRpc::HealthSummary.for_patient(d) },
  "HealthSummary.clinical_reminders" => -> { RpmsRpc::HealthSummary.clinical_reminders(d) },
  "BehavioralHealth.visits" => -> { RpmsRpc::BehavioralHealth.visits(d, from: year_ago, to: today) },
  "BehavioralHealth.treatment_plans" => -> { RpmsRpc::BehavioralHealth.treatment_plans(d, from: year_ago, to: today) },
  "BehavioralHealth.suicide_forms" => -> { RpmsRpc::BehavioralHealth.suicide_forms(d, from: year_ago, to: today) },
  # reference data
  "Symptom.defaults" => -> { RpmsRpc::Symptom.defaults },
  "Symptom.search(\"COUGH\")" => -> { RpmsRpc::Symptom.search("COUGH") },
  "Allergen.search(\"PENIC\")" => -> { RpmsRpc::Allergen.search("PENIC") },
  "Problem.lex_search(\"DIABETES\")" => -> { RpmsRpc::Problem.lex_search("DIABETES") },
  "ImmunizationRefusal.reasons" => -> { RpmsRpc::ImmunizationRefusal.reasons },
  "Tribal.tribes" => -> { RpmsRpc::Tribal.tribes },
  "Order.all_sheets" => -> { RpmsRpc::Order.all_sheets },
  "Scheduling.clinic_setup" => -> { RpmsRpc::Scheduling.clinic_setup },
  "Scheduling.all_appointments(30d)" => -> { RpmsRpc::Scheduling.all_appointments(start_date: today - 30, end_date: today + 30) },
  "Referral.purposes" => -> { RpmsRpc::Referral.purposes },
  "Referral.health_summary_types" => -> { RpmsRpc::Referral.health_summary_types }
}
# Vital.template takes the patient and a visit string (#259); Encounter.visit_string builds that string locally and
# sends no RPC, so it is an argument here, not a case (#795).
cases["Vital.template"] = -> { RpmsRpc::Vital.template(d, RpmsRpc::Encounter.visit_string(ctx[:location], today, "A")) } if ctx[:location]
cases["Reminders.applicable"] = -> { RpmsRpc::Reminders.applicable(d, ctx[:location]) } # location optional: sent empty when unknown (#238)
cases["BehavioralHealth.visit_information"] = -> { RpmsRpc::BehavioralHealth.visit_information(ctx[:visit]) } if ctx[:visit]
cases["ProgressNote.fetch_text"] = -> { RpmsRpc::ProgressNote.fetch_text(ctx[:note]) } if ctx[:note]
cases["Order.result"] = -> { RpmsRpc::Order.result(d, ctx[:order]) } if ctx[:order]
cases["Order.result_history"] = -> { RpmsRpc::Order.result_history(d, ctx[:order]) } if ctx[:order]
cases["Problem.details"] = -> { RpmsRpc::Problem.details(d, ctx[:problem]) } if ctx[:problem]
cases["Problem.audit_history"] = -> { RpmsRpc::Problem.audit_history(ctx[:problem]) } if ctx[:problem]
cases["NoteTemplate.items"] = -> { RpmsRpc::NoteTemplate.items(ctx[:template]) } if ctx[:template]
cases["NoteTemplate.boilerplate"] = -> { RpmsRpc::NoteTemplate.boilerplate(ctx[:template]) } if ctx[:template]
cases["NoteTemplate.text"] = -> { RpmsRpc::NoteTemplate.text([ "|PATIENT NAME|" ], dfn: ctx[:dfn]) }
# The Behavioral Health reads run under AMHGRPC, which IHS gives only to BH staff: a role without it (the provider, since
# openrpms#1299) is refused them by design, so they run only as a role that holds it (README, Test roles).
unless ROLE.holds?(RpmsRpc::BehavioralHealth::CONTEXT)
  not_run = cases.keys.grep(/\ABehavioralHealth\./)
  not_run.each { |name| cases.delete(name) }
  puts "not run: #{not_run.join(', ')} (#{ROLE.name} does not hold #{RpmsRpc::BehavioralHealth::CONTEXT})" unless not_run.empty?
end

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
# argv form, no shell: the checkout path may contain spaces. No git, or not a checkout -> no "@ rev".
rev = begin
  IO.popen([ "git", "-C", File.expand_path("../..", __dir__), "rev-parse", "--short", "HEAD" ], err: File::NULL, &:read).to_s.strip
rescue SystemCallError
  ""
end
run_meta = {
  "at" => now, "rpms_rpc" => "#{RpmsRpc::VERSION}#{rev.empty? ? '' : " @ #{rev}"}", "host_label" => BACKEND, "role" => ROLE.name.to_s,
  "context" => CONTEXT || "#{RpmsRpc::CiaClient::SIGNON_CONTEXT} (sign-on)", "cases" => results.size,
  "tally" => tally, "signons" => $signons
}
evidence = RpcCoverage.load_evidence(EVIDENCE, BACKEND)
evidence = RpcCoverage.merge_run(evidence, run_meta, outcomes)
problems = RpcCoverage.evidence_problems(evidence, secrets: [ ACCESS, VERIFY ], role: ROLE.name.to_s)
abort("!! refusing to write evidence: #{problems.join('; ')}") unless problems.empty?
File.write(EVIDENCE, JSON.pretty_generate(evidence) + "\n")
unless ENV["CASES"].to_s.empty?
  File.write(ENV["CASES"], results.map { |r|
    JSON.generate({ "case" => r[:case], "verdict" => r[:verdict], "error" => r[:error], "role" => ROLE.name.to_s,
                    "rpcs" => r[:wire].map { |w| { "rpc" => w[:rpc].to_s, "reply" => w[:reply].to_s } } }) + "\n"
  }.join)
end

puts
puts "cases: #{results.size}  #{tally.sort.map { |k, v| "#{k}=#{v}" }.join('  ')}"
puts "sign-ons: #{$signons} (1 + one per dropped session)"
puts "distinct RPCs sent: #{outcomes.size}  (answered: #{outcomes.count { |_, o| o['outcome'] == 'ok' }}, errored: #{outcomes.count { |_, o| o['outcome'] == 'error' }})"
puts "merged into #{EVIDENCE} (#{evidence['rpcs'].size} RPCs across #{evidence['runs'].size} run(s))"
puts "cases written to #{ENV['CASES']}" unless ENV["CASES"].to_s.empty?
