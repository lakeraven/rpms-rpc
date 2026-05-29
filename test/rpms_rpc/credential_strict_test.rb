# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/client"

# Tests for the credential-strict behavior — credentials must be set
# explicitly (or via env) in non-development environments. Falling through
# to the legacy `PROV123` debug defaults must hard-fail in production so a
# misconfigured deploy can't silently talk to the broker as a debug account.
class CredentialStrictTest < Minitest::Test
  Client = RpmsRpc::Client
  DEV_ACCESS = "PROV123"
  DEV_VERIFY = "PROV123!!"

  def setup
    @prev = {
      "RPMS_ACCESS_CODE" => ENV["RPMS_ACCESS_CODE"],
      "RPMS_VERIFY_CODE" => ENV["RPMS_VERIFY_CODE"],
      "VISTA_RPC_ENV" => ENV["VISTA_RPC_ENV"]
    }
    %w[RPMS_ACCESS_CODE RPMS_VERIFY_CODE VISTA_RPC_ENV].each { |k| ENV.delete(k) }
  end

  def teardown
    @prev.each { |k, v| ENV[k] = v }
  end

  # --- development env preserves the legacy fallback (so dev workflows keep working) ---

  def test_development_env_falls_through_to_dev_defaults_when_creds_unset
    ENV["VISTA_RPC_ENV"] = "development"
    client = Client.new
    ac, vc = client.send(:resolve_credentials, nil, nil)
    assert_equal DEV_ACCESS, ac
    assert_equal DEV_VERIFY, vc
  end

  def test_development_env_accepts_explicit_credentials
    ENV["VISTA_RPC_ENV"] = "development"
    client = Client.new
    ac, vc = client.send(:resolve_credentials, "REAL", "REAL!!")
    assert_equal "REAL", ac
    assert_equal "REAL!!", vc
  end

  # --- non-development env: hard-fail on unset / default creds ---

  def test_production_env_raises_when_credentials_are_unset
    ENV["VISTA_RPC_ENV"] = "production"
    client = Client.new

    err = assert_raises(RpmsRpc::Client::CredentialError) do
      client.send(:resolve_credentials, nil, nil)
    end
    assert_match(/RPMS_ACCESS_CODE|production|credential/i, err.message)
  end

  def test_production_env_raises_when_env_values_are_dev_defaults
    ENV["VISTA_RPC_ENV"] = "production"
    ENV["RPMS_ACCESS_CODE"] = DEV_ACCESS
    ENV["RPMS_VERIFY_CODE"] = DEV_VERIFY
    client = Client.new

    assert_raises(RpmsRpc::Client::CredentialError) do
      client.send(:resolve_credentials, nil, nil)
    end
  end

  def test_production_env_raises_when_only_access_code_is_a_dev_default
    ENV["VISTA_RPC_ENV"] = "production"
    ENV["RPMS_ACCESS_CODE"] = DEV_ACCESS
    ENV["RPMS_VERIFY_CODE"] = "REAL!!"
    client = Client.new

    assert_raises(RpmsRpc::Client::CredentialError) do
      client.send(:resolve_credentials, nil, nil)
    end
  end

  def test_production_env_raises_when_only_verify_code_is_a_dev_default
    ENV["VISTA_RPC_ENV"] = "production"
    ENV["RPMS_ACCESS_CODE"] = "REAL"
    ENV["RPMS_VERIFY_CODE"] = DEV_VERIFY
    client = Client.new

    assert_raises(RpmsRpc::Client::CredentialError) do
      client.send(:resolve_credentials, nil, nil)
    end
  end

  def test_production_env_raises_on_blank_or_whitespace_credentials
    ENV["VISTA_RPC_ENV"] = "production"
    client = Client.new

    [ "", "   ", "\t\n" ].each do |blank|
      ENV["RPMS_ACCESS_CODE"] = blank
      ENV["RPMS_VERIFY_CODE"] = "REAL!!"
      assert_raises(RpmsRpc::Client::CredentialError) do
        client.send(:resolve_credentials, nil, nil)
      end

      ENV["RPMS_ACCESS_CODE"] = "REAL"
      ENV["RPMS_VERIFY_CODE"] = blank
      assert_raises(RpmsRpc::Client::CredentialError) do
        client.send(:resolve_credentials, nil, nil)
      end
    end
  end

  def test_production_env_raises_when_explicit_args_are_dev_defaults
    # The doc + Copilot review correctly note: explicit args take the
    # same path; passing PROV123 / PROV123!! literally must also raise.
    ENV["VISTA_RPC_ENV"] = "production"
    client = Client.new

    assert_raises(RpmsRpc::Client::CredentialError) do
      client.send(:resolve_credentials, DEV_ACCESS, DEV_VERIFY)
    end
  end

  def test_production_env_accepts_explicit_non_default_credentials
    ENV["VISTA_RPC_ENV"] = "production"
    client = Client.new

    ac, vc = client.send(:resolve_credentials, "REAL", "REAL!!")
    assert_equal "REAL", ac
    assert_equal "REAL!!", vc
  end

  def test_production_env_accepts_env_supplied_non_default_credentials
    ENV["VISTA_RPC_ENV"] = "production"
    ENV["RPMS_ACCESS_CODE"] = "REALPROV"
    ENV["RPMS_VERIFY_CODE"] = "REALPROV!!"
    client = Client.new

    ac, vc = client.send(:resolve_credentials, nil, nil)
    assert_equal "REALPROV", ac
    assert_equal "REALPROV!!", vc
  end

  # --- VISTA_RPC_ENV defaults to production (strict-by-default) ---

  def test_unset_environment_defaults_to_strict_production
    # VISTA_RPC_ENV unset, no Rails
    client = Client.new
    assert_raises(RpmsRpc::Client::CredentialError) do
      client.send(:resolve_credentials, nil, nil)
    end
  end

  # --- Rails.env branches of development_environment? -----------------------

  # Minimal Rails / Rails.env stub so tests don't need to load Rails.
  class FakeRailsEnv
    def initialize(name); @name = name; end
    def development?; @name == "development"; end
    def production?;  @name == "production"; end
    def to_s; @name; end
  end

  module FakeRails
    class << self
      attr_accessor :env
    end
  end

  def with_rails_const(env_name)
    Object.const_set(:Rails, FakeRails)
    FakeRails.env = env_name.nil? ? nil : FakeRailsEnv.new(env_name)
    yield
  ensure
    Object.send(:remove_const, :Rails) if Object.const_defined?(:Rails)
  end

  def test_rails_development_env_uses_dev_fallback
    with_rails_const("development") do
      client = Client.new
      ac, vc = client.send(:resolve_credentials, nil, nil)
      assert_equal DEV_ACCESS, ac
      assert_equal DEV_VERIFY, vc
    end
  end

  def test_rails_production_env_raises_on_unset_credentials
    with_rails_const("production") do
      client = Client.new
      assert_raises(RpmsRpc::Client::CredentialError) do
        client.send(:resolve_credentials, nil, nil)
      end
    end
  end

  def test_rails_env_nil_falls_back_to_vista_rpc_env_check
    # Rails defined but Rails.env is nil — treat as production-strict
    # (the strict-by-default rule applies).
    with_rails_const(nil) do
      client = Client.new
      assert_raises(RpmsRpc::Client::CredentialError) do
        client.send(:resolve_credentials, nil, nil)
      end
    end
  end

  # --- CredentialError is an AuthenticationError subclass (preserves catch shape) ---

  def test_credential_error_is_an_authentication_error
    assert_operator RpmsRpc::Client::CredentialError, :<, RpmsRpc::Client::AuthenticationError
  end
end
