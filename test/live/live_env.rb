# frozen_string_literal: true

require "yaml"
require_relative "../../lib/rpms_rpc/live_summary"
require_relative "../../lib/rpms_rpc/test_roles"

# The live-spec settings, without Minitest, so the Rakefile can check them
# before `rake test:live` loads a single spec. See live_helper.rb.
module LiveSpec
  REQUIRED_ENV = %w[BROKER_HOST BROKER_PORT ROLE].freeze
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

  # The roles a live spec runs as (README, Test roles). Each spec declares the
  # role whose work it proves (`runs_as :scheduler`), and a run signs on as one
  # role and runs only the specs that declare it. A role's account, pair, keys,
  # options and XUPROGMODE are its row in RpmsRpc::TestRoles, and nowhere else.
  ROLES = RpmsRpc::TestRoles

  # An openrpms-ux scenario id, as a spec's `proves` names it: S-SCH-01.1.
  SCENARIO_ID = /\AS-[A-Z]+-\d+\.\d+\z/

  module_function

  # The role ROLE names, or nil.
  def role(env = ENV) = ROLES[env["ROLE"]]

  # nil when ROLE names a test role and no retired PERSONA is set, else the reason.
  def role_error(env = ENV)
    retired = ROLES.retired_persona_message(env)
    return retired if retired

    name = env["ROLE"].to_s.strip
    return nil if name.empty? || ROLES[name]

    ROLES.unknown_message(name)
  end

  # The pair a run signs on with: RPMS_ACCESS and RPMS_VERIFY when set (a stack
  # whose codes differ from the build's), else the role's published pair.
  def sign_on_pair(env = ENV)
    row = role(env)
    [ present(env["RPMS_ACCESS"]) || row&.access, present(env["RPMS_VERIFY"]) || row&.verify ]
  end

  # The electronic signature code: RPMS_ESIG when set, else the role's.
  def esig(env = ENV) = present(env["RPMS_ESIG"]) || role(env)&.esig

  # The XUPROGMODE guard's verdict for this process: nil when the signed-on
  # account holds XUPROGMODE exactly when ROW says so, else the reason the run
  # fails. The block asks the broker (Authentication.held_keys(["XUPROGMODE"]):
  # the names held, nil when it could not ask, or why it could not sign on)
  # and runs once per role.
  def xuprogmode_verdict(row)
    @xuprogmode_verdicts ||= {}
    return @xuprogmode_verdicts[row.name] if @xuprogmode_verdicts.key?(row.name)

    held = yield
    @xuprogmode_verdicts[row.name] =
      if held.is_a?(String)
        held
      elsif held.nil?
        "could not ask whether #{row.account} holds XUPROGMODE (ORWU NPHASKEY under CIAV VUECENTRIC was " \
          "refused or unreadable), so the run cannot show it signed on as #{row.name}"
      else
        ROLES.xuprogmode_mismatch(row, holds: held.include?("XUPROGMODE"))
      end
  end

  def forget_xuprogmode_verdicts! = (@xuprogmode_verdicts = {})

  # Whether this process refused ROLE because its account's XUPROGMODE disagreed with the row.
  def xuprogmode_refused?(role) = !(@xuprogmode_verdicts || {})[role.to_s.strip.to_sym].nil?

  # The roles each spec file declares, read from its `runs_as` lines, so the
  # runner can say which role runs what without loading a spec.
  def declared_roles(path)
    File.read(path).scan(/^\s*runs_as\s+(.+)$/).flat_map { |(args)| args.scan(/:([a-z_]+)/).flatten.map(&:to_sym) }.uniq
  end

  # The scenarios each spec file declares, read from its `proves` lines, so
  # `rake rpc:coverage` can list them without loading a spec.
  def declared_scenarios(path)
    File.read(path).scan(/^\s*proves\s+(.+)$/).flat_map { |(args)| args.scan(/"(S-[A-Z]+-\d+\.\d+)"/).flatten }.uniq
  end

  # { spec file => { roles:, scenarios: } } for every spec of any protocol that declares a scenario.
  def scenario_plan(root: File.expand_path("../..", __dir__))
    SPEC_GLOBS.values.flat_map { |glob| Dir[File.join(root, glob)] }.sort.filter_map do |f|
      scenarios = declared_scenarios(f)
      [ f.delete_prefix("#{root}/"), { roles: declared_roles(f), scenarios: scenarios } ] unless scenarios.empty?
    end.to_h
  end

  # { role => [spec files] } for a protocol's specs, in table order.
  def role_plan(protocol = "cia", root: File.expand_path("../..", __dir__))
    files = Dir[File.join(root, SPEC_GLOBS.fetch(protocol))].sort
    ROLES.names.to_h do |name|
      [ name, files.select { |f| declared_roles(f).include?(name) }.map { |f| f.delete_prefix("#{root}/") } ]
    end
  end

  # The roles at least one spec of any protocol declares: CI's matrix.
  def roles_in_use(root: File.expand_path("../..", __dir__))
    files = SPEC_GLOBS.values.flat_map { |glob| Dir[File.join(root, glob)] }
    used = files.flat_map { |f| declared_roles(f) }.uniq
    ROLES.names.select { |name| used.include?(name) }
  end

  # The names of the required variables that are unset or blank.
  # RPMS_VERIFY is one of them for a row with no published verify code.
  def missing_env(env = ENV)
    missing = REQUIRED_ENV.select { |k| env[k].to_s.strip.empty? }
    missing << "RPMS_VERIFY" if role(env) && sign_on_pair(env).last.nil?
    missing
  end

  def present(value)
    value = value.to_s.strip
    value.empty? ? nil : value
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
      "Set BROKER_HOST and BROKER_PORT (a local container, or an SSM tunnel to a stack) and\n" \
      "ROLE, the test role the run signs on as (e.g. ROLE=provider; README, Test roles). A role\n" \
      "signs on with its published pair unless RPMS_ACCESS/RPMS_VERIFY say otherwise (a target\n" \
      "other than an openrpms -demo image sets its own). See test/live/live_helper.rb."
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
