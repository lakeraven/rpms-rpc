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

  # --- CredentialError is an AuthenticationError subclass (preserves catch shape) ---

  def test_credential_error_is_an_authentication_error
    assert_operator RpmsRpc::Client::CredentialError, :<, RpmsRpc::Client::AuthenticationError
  end
end
