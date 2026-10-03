# frozen_string_literal: true

require "yaml"

# The live-spec settings, without Minitest, so the Rakefile can check them
# before `rake test:live` loads a single spec. See live_helper.rb.
module LiveSpec
  REQUIRED_ENV = %w[BROKER_HOST BROKER_PORT RPMS_ACCESS RPMS_VERIFY PERSONA].freeze
  LOOPBACK_HOSTS = %w[127.0.0.1 localhost ::1].freeze
  COVERAGE_CONFIG = File.expand_path("../../data/rpc_coverage/config.yml", __dir__)

  module_function

  # The names of the required variables that are unset or blank.
  def missing_env(env = ENV)
    REQUIRED_ENV.select { |k| env[k].to_s.strip.empty? }
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

  # The release the specs are pinned to. The gem has no live read of the
  # server's build yet, so this is the pin, labelled as such.
  def build_label
    registry = YAML.safe_load_file(COVERAGE_CONFIG)["registry"].to_s
    "#{File.basename(registry, '.txt')} (pinned, not verified: data/rpc_coverage/config.yml)"
  rescue StandardError => e
    "unknown (no pinned release readable: #{e.class})"
  end
end
