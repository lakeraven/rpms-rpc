# frozen_string_literal: true

# Run openrpms' wire-level conformance cases against ONE live CIA broker (openrpms#834):
# `rake rpc:cases`. The cases are data (see case_runner.rb); this signs on as a test role, refuses
# an account that is not the role's or whose XUPROGMODE disagrees with its row, runs the rows
# written for that role and writes one verdict per case.
#
# Env: CASES (path to cases.jsonl), BROKER_HOST (default 127.0.0.1), BROKER_PORT,
#      ROLE (the test role, README, Test roles), RPMS_ACCESS, RPMS_VERIFY (optional: the pair, when the
#      target's differs from the role's published one; ROLE=operator needs RPMS_VERIFY), CASE_TIMEOUT (45 s),
#      OUT (optional: write the verdicts there, one JSON object per line)
# Exit: 0 = every case of the role gave its expected verdict; 1 = anything else.
# The access and verify codes are read from the environment and never written.
require "json"

LIB = File.expand_path("../../lib", __dir__)
$LOAD_PATH.unshift(LIB)
require "rpms_rpc/cia_client"
require_relative "case_runner"

cases_path = ENV.fetch("CASES")
begin
  role = RpcCoverage.run_role(ENV)
  access, verify = RpcCoverage.sign_on_pair(role, ENV)
rescue RpcCoverage::Error => e
  abort("!! #{e.message}")
end
host = ENV.fetch("BROKER_HOST", "127.0.0.1")
port = Integer(ENV.fetch("BROKER_PORT"))
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
if (problem = RpcCoverage.signed_on_problem(role, user: client.signon_user, holds_progmode: progmode))
  abort("!! #{problem}")
end
mine = rows.select { |r| r["role"] == role.name.to_s }
abort("!! #{cases_path} has no case for role #{role.name}") if mine.empty?
duz = client.duz.to_s
puts "cases: #{cases_path} (#{mine.size} for #{role.name}, #{rows.size - mine.size} for other roles)"
puts "signed on: DUZ=#{duz} role=#{role.name} (#{role.account}; XUPROGMODE #{progmode ? 'held' : 'not held'})"

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
