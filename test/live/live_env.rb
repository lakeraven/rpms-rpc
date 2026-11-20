# frozen_string_literal: true

require "yaml"
require_relative "../../lib/rpms_rpc/live_summary"

# The live-spec settings, without Minitest, so the Rakefile can check them
# before `rake test:live` loads a single spec. See live_helper.rb.
module LiveSpec
  REQUIRED_ENV = %w[BROKER_HOST BROKER_PORT RPMS_ACCESS RPMS_VERIFY PERSONA].freeze
  LOOPBACK_HOSTS = %w[127.0.0.1 localhost ::1].freeze

  # The broker line a run speaks, from BROKER_PROTOCOL (default cia). Each
  # spec is written for one line: CIA specs live in test/live/, XWB specs in
  # test/live/xwb/, BMX specs in test/live/bmx/, and `rake test:live` loads only the directory of the
  # protocol the run names. A spec declares its line (`broker :xwb`), so one
  # loaded by path under the other protocol fails, naming the setting.
  PROTOCOLS = %w[cia xwb bmx].freeze
  SPEC_GLOBS = {
    "cia" => "test/live/*_test.rb",
    "xwb" => "test/live/xwb/**/*_test.rb",
    "bmx" => "test/live/bmx/**/*_test.rb"
  }.freeze

  # The personas a live spec runs as (#452). Each spec declares the persona
  # whose role it proves (`runs_as "PREG123"`), the least privilege that role
  # needs, and a run signs on as one persona and runs only the specs that
  # declare it. The users are the build's published demo personas (SEEDPERS)
  # and its operator. README, "Live personas", says which runs what.
  PERSONAS = {
    "PROV123" => "PROVIDER,TEST: the clinician the pilot web tier signs on as (chart reads, notes, visits, referrals, Behavioral Health)",
    "PMD123" => "PROFILE,MD: the physician (orders it authored, alerts, clinical writes PROV123 is not given)",
    "PREG123" => "PROFILE,REG: registration (AGGRPC, and BMXRPC for the duplicate lookup)",
    "PSCH123" => "PROFILE,SCHED: scheduling (BSDXRPC)",
    "SYS123" => "MANAGER,SYSTEM: the operator (coverage writes, which need BQIRPC no registration persona holds; build setup)"
  }.freeze

  module_function

  # nil when PERSONA names a persona a live spec can run as, else the reason.
  def persona_error(env = ENV)
    name = env["PERSONA"].to_s.strip
    return nil if name.empty? || PERSONAS.key?(name)

    "PERSONA=#{name.inspect} is not one of #{PERSONAS.keys.join(', ')} (see README, Live personas)"
  end

  # The personas each spec file declares, read from its `runs_as` lines, so
  # the runner can say which persona runs what without loading a spec.
  def declared_personas(path)
    File.read(path).scan(/^\s*runs_as\s+(.+)$/).flat_map { |(args)| args.scan(/"([A-Z0-9]+)"/).flatten }.uniq
  end

  # { persona => [spec files] } for a protocol's specs, in PERSONAS order.
  def persona_plan(protocol = "cia", root: File.expand_path("../..", __dir__))
    files = Dir[File.join(root, SPEC_GLOBS.fetch(protocol))].sort
    PERSONAS.keys.to_h do |name|
      [ name, files.select { |f| declared_personas(f).include?(name) }.map { |f| f.delete_prefix("#{root}/") } ]
    end
  end

  # The names of the required variables that are unset or blank.
  def missing_env(env = ENV)
    REQUIRED_ENV.select { |k| env[k].to_s.strip.empty? }
  end

  # The run's broker protocol: "cia", "xwb" or "bmx".
  def protocol(env = ENV)
    value = env["BROKER_PROTOCOL"].to_s.strip.downcase
    value.empty? ? "cia" : value
  end

  # nil when BROKER_PROTOCOL names a line the harness speaks, else the reason.
  def protocol_error(env = ENV)
    return nil if PROTOCOLS.include?(protocol(env))

    "BROKER_PROTOCOL=#{env['BROKER_PROTOCOL'].inspect} is not one of #{PROTOCOLS.join(', ')}"
  end

  # What to tell someone who ran the live specs without their settings.
  def missing_env_message(missing)
    "live specs sign on to an RPMS broker, and these settings are missing: #{missing.join(', ')}.\n" \
      "Set BROKER_HOST and BROKER_PORT (a local container, or an SSM tunnel to a stack),\n" \
      "RPMS_ACCESS and RPMS_VERIFY (the persona's sign-on pair) and PERSONA (e.g. PROV123);\n" \
      "PROV123 also needs VISTA_RPC_ENV=development. See test/live/live_helper.rb."
  end

  # nil when a writing spec may run against this env, else the reason it may not.
  def write_refusal(env = ENV)
    return "LIVE_DISPOSABLE=1 is not set: the target is not declared disposable" unless env["LIVE_DISPOSABLE"] == "1"
    return "BROKER_HOST #{env['BROKER_HOST'].inspect} is not loopback: writes go only to a local container" unless LOOPBACK_HOSTS.include?(env["BROKER_HOST"].to_s)

    nil
  end

  # The release the specs run against: the openrpms release under test, the one `rake openrpms:fetch`
  # recorded (rpms-rpc#724). The gem has no live read of the server's build yet, so this is that record,
  # labelled as such. A run against another build names it in LIVE_BUILD, labelled as the runner's word.
  def build_label(env = ENV)
    declared = env["LIVE_BUILD"].to_s.strip
    return "#{declared} (declared by LIVE_BUILD, not verified)" unless declared.empty?

    "#{RpmsRpc::LiveSummary.release_build(env)} (release under test, not verified: tmp/openrpms/current.json)"
  rescue StandardError => e
    "unknown (no release under test recorded: #{e.class}; run rake openrpms:fetch)"
  end
end
