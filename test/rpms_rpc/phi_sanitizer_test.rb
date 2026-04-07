# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/phi_sanitizer"

class RpmsRpc::PhiSanitizerTest < Minitest::Test
  S = RpmsRpc::PhiSanitizer

  def setup
    S.secret_key = "test-secret-key"
  end

  # -- hash_identifier --------------------------------------------------------

  def test_hash_identifier_returns_12_char_hash
    assert_equal 12, S.hash_identifier("12345").length
  end

  def test_hash_identifier_is_consistent
    a = S.hash_identifier("12345")
    b = S.hash_identifier("12345")
    assert_equal a, b
  end

  def test_hash_identifier_is_different_for_different_input
    refute_equal S.hash_identifier("12345"), S.hash_identifier("67890")
  end

  def test_hash_identifier_returns_nil_for_blank
    assert_nil S.hash_identifier(nil)
    assert_nil S.hash_identifier("")
  end

  def test_hash_identifier_handles_integer
    assert_equal 12, S.hash_identifier(12345).length
  end

  # -- sanitize_message: names ------------------------------------------------

  def test_sanitize_message_redacts_vista_format_names
    msg = "Patient SMITH,JOHN had an issue"
    assert_includes S.sanitize_message(msg), "[NAME-REDACTED]"
    refute_includes S.sanitize_message(msg), "SMITH,JOHN"
  end

  def test_sanitize_message_redacts_patient_name_pattern
    msg = "patient_name: JONES,MARY"
    refute_includes S.sanitize_message(msg), "JONES,MARY"
  end

  # -- sanitize_message: identifiers ------------------------------------------

  def test_sanitize_message_redacts_ssn
    msg = "SSN is 123-45-6789"
    assert_includes S.sanitize_message(msg), "[SSN-REDACTED]"
    refute_includes S.sanitize_message(msg), "123-45-6789"
  end

  def test_sanitize_message_redacts_dfn
    msg = "DFN: 12345 not found"
    assert_includes S.sanitize_message(msg), "DFN:[REDACTED]"
    refute_includes S.sanitize_message(msg), "DFN: 12345"
  end

  def test_sanitize_message_redacts_phone
    msg = "Call (907) 555-1234"
    assert_includes S.sanitize_message(msg), "[PHONE-REDACTED]"
    refute_includes S.sanitize_message(msg), "555-1234"
  end

  def test_sanitize_message_returns_empty_for_nil
    assert_equal "", S.sanitize_message(nil)
  end

  # -- sanitize_hash ----------------------------------------------------------

  def test_sanitize_hash_hashes_phi_fields
    result = S.sanitize_hash(patient_dfn: "12345", name: "Test")
    refute_equal "12345", result[:patient_id_hash]
    assert_equal "Test", result[:name]
  end

  def test_sanitize_hash_redacts_ssn_to_presence_flag
    result = S.sanitize_hash(ssn: "123-45-6789")
    assert_equal true, result[:ssn_present]
  end

  def test_sanitize_hash_handles_nested_hashes
    result = S.sanitize_hash(outer: { patient_dfn: "12345" })
    assert_equal Hash, result[:outer].class
    refute_equal "12345", result[:outer][:patient_id_hash]
  end

  def test_sanitize_hash_returns_empty_for_nil
    assert_equal({}, S.sanitize_hash(nil))
  end

  # -- safe_patient_context ---------------------------------------------------

  def test_safe_patient_context_returns_hashed_dfn
    context = S.safe_patient_context("12345")
    assert context[:patient_id_hash]
    refute_equal "12345", context[:patient_id_hash]
  end

  # -- works without Rails ----------------------------------------------------

  def test_works_without_rails
    refute defined?(Rails), "Rails should not be loaded in this test"
    assert S.hash_identifier("test")
  end
end
