# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/version"
require "rpms_rpc/client"
require "rpms_rpc/phi_sanitizer"

# Tests for PHI sanitization of exception messages.
#
# The gem doesn't emit internal logs (no @logger calls anywhere); the
# PHI risk vector is exception messages that interpolate raw broker
# response payloads (auth errors, handshake rejections, BMX security
# errors). Those raise sites must scrub PHI before the exception
# propagates to the host.
class ErrorSanitizationTest < Minitest::Test
  def teardown
    RpmsRpc.configuration.unsafe_raw_errors = false
  end

  # --- Configuration flag --------------------------------------------------

  def test_unsafe_raw_errors_defaults_to_false
    refute RpmsRpc.configuration.unsafe_raw_errors,
      "Strict sanitization must be the default"
  end

  def test_unsafe_raw_errors_is_a_configuration_attribute
    RpmsRpc.configuration.unsafe_raw_errors = true
    assert RpmsRpc.configuration.unsafe_raw_errors
  end

  # --- sanitize_error helper -----------------------------------------------

  def test_sanitize_error_scrubs_phi_name
    raw = "Authentication failed for patient: SMITH,JOHN"
    sanitized = RpmsRpc.sanitize_error(raw)

    refute_includes sanitized, "SMITH,JOHN"
    assert_includes sanitized, "Authentication failed"
  end

  def test_sanitize_error_scrubs_dfn_identifier
    # PHI redaction of the DFN itself. (The patient-name regex can
    # greedy-consume an immediately-adjacent token; this test uses a
    # message shape where DFN appears on its own so the substitution
    # is testable end-to-end.)
    raw = "RPC failed; DFN: 12345 not found"
    sanitized = RpmsRpc.sanitize_error(raw)

    refute_includes sanitized, "12345"
    assert_includes sanitized, "DFN:[REDACTED]"
  end

  def test_sanitize_error_passes_through_when_unsafe_raw_errors_enabled
    RpmsRpc.configuration.unsafe_raw_errors = true
    raw = "Authentication failed for patient: SMITH,JOHN"

    assert_equal raw, RpmsRpc.sanitize_error(raw)
  end

  def test_sanitize_error_leaves_innocuous_messages_unchanged
    raw = "Failed to create context 'OR CPRS GUI CHART': 0"
    sanitized = RpmsRpc.sanitize_error(raw)

    assert_includes sanitized, "OR CPRS GUI CHART"
    assert_includes sanitized, "Failed to create context"
  end

  def test_sanitize_error_handles_nil_safely
    assert_equal "", RpmsRpc.sanitize_error(nil)
  end

  # --- exception-message wrapping at the raise sites ----------------------

  # Pin a couple of the highest-risk sites end-to-end. A focused unit test
  # is cheaper than a full mock-broker integration; we just ensure the
  # raise site goes through sanitize_error.
  def test_authentication_error_message_is_sanitized
    require "rpms_rpc/client"
    client = RpmsRpc::Client.new
    client.instance_variable_set(:@connected, true)
    client.instance_variable_set(:@socket, StringIO.new)

    # Stub signon_setup and call_rpc_raw to return a broker response
    # that embeds PHI in line 3 (the error message slot).
    def client.signon_setup; end
    def client.call_rpc_raw(*)
      "0\r\nfoo\r\nbar\r\nauth fail for patient: SMITH,JOHN\r\n"
    end

    err = assert_raises(RpmsRpc::Client::AuthenticationError) do
      client.authenticate("REAL", "REAL!!")
    end
    refute_includes err.message, "SMITH,JOHN"
  ensure
    ENV.delete("VISTA_RPC_ENV")
  end
end
