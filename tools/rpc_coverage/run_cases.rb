# frozen_string_literal: true

# Run rpms-ops' wire-level conformance cases against ONE live CIA broker (rpms-ops#834):
# `rake rpc:cases`. The cases are data (see case_runner.rb); this signs on, reads the persona from
# who signed on (#397), runs the rows written for that persona and writes one verdict per case.
#
# Env: CASES (path to cases.jsonl), BROKER_HOST (default 127.0.0.1), BROKER_PORT, RPMS_ACCESS,
#      RPMS_VERIFY, PERSONA (optional expectation: least_privilege or programmer), CASE_TIMEOUT (45 s),
#      OUT (optional: write the verdicts there, one JSON object per line)
# Exit: 0 = every case of the persona gave its expected verdict; 1 = anything else.
# The access and verify codes are read from the environment and never written.
require "json"

LIB = File.expand_path("../../lib", __dir__)
$LOAD_PATH.unshift(LIB)
require "rpms_rpc/cia_client"
require_relative "case_runner"

cases_path = ENV.fetch("CASES")
expected = RpcCoverage.expected_persona(ENV["PERSONA"])
host = ENV.fetch("BROKER_HOST", "127.0.0.1")
port = Integer(ENV.fetch("BROKER_PORT"))
access = ENV.fetch("RPMS_ACCESS")
verify = ENV.fetch("RPMS_VERIFY")
out = ENV["OUT"].to_s

rows = RpcCoverage::Cases.load(cases_path)
signons = 0
connect = lambda do
  attempt = 0
  begin
    attempt += 1
    c = RpmsRpc::CiaClient.new(host: host, port: port, timeout: 30)
    c.connect
    c.authenticate(access, verify)
    signons += 1
    c
  rescue RpmsRpc::Client::ConnectionError, IOError, SystemCallError
    raise if attempt >= 5

    sleep(2 * attempt)
    retry
  end
end

client = connect.call
progmode = RpcCoverage.holds_progmode?(client.call_rpc_lines("ORWU HASKEY", "XUPROGMODE"))
persona = RpcCoverage.persona_of(holds_progmode: progmode)
if (problem = RpcCoverage.persona_problem(expected, persona))
  abort("!! #{problem}")
end
mine = rows.select { |r| r["persona"] == persona }
abort("!! #{cases_path} has no case for persona #{persona}") if mine.empty?
duz = client.duz.to_s
puts "cases: #{cases_path} (#{mine.size} for #{persona}, #{rows.size - mine.size} for other personas)"
puts "signed on: DUZ=#{duz} persona=#{persona} (XUPROGMODE #{progmode ? 'held' : 'not held'})"

runner = RpcCoverage::Cases::Runner.new(mine, duz: duz, connect: connect,
                                              timeout: Integer(ENV.fetch("CASE_TIMEOUT", "45")))
last = runner.run(client) do |r|
  printf("%-4s %-15s %-32s %-30s %s\n", r["pass"] ? "ok" : "FAIL", r["verdict"], r["id"], r["rpc"],
         r["detail"].to_s[0, 90])
end
begin
  last.disconnect
rescue StandardError
  nil
end

results = runner.results
text = results.map { |r| JSON.generate(r) }.join("\n") + "\n"
abort("!! a verdict carries a sign-on code; nothing written") if [ access, verify ].any? { |s| !s.empty? && text.include?(s) }
File.write(out, text) unless out.empty?

failed = results.reject { |r| r["pass"] }
puts
puts "cases: #{results.size}  passed: #{results.size - failed.size}  failed: #{failed.size}  sign-ons: #{signons}"
puts "verdicts: #{out}" unless out.empty?
exit(failed.empty? ? 0 : 1)
