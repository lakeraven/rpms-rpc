# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"

# Tests for patient section-based editing via BEHOENCX AGG RPCs.
# Exercises section_data (text_blob), section_definition (text_blob),
# patient_lock, and patient_unlock through the mock client.
class PatientSectionsTest < Minitest::Test
  def setup
    RpmsRpc.mock! do |m|
      m.seed(:section_data, "1", "NAME: DOE,JOHN\nSEX: M\nDOB: 01/15/1980\nSSN: ***-**-3333")
      m.seed(:section_data, "2", "NAME: SMITH,JANE\nSEX: F\nDOB: 03/22/1992")
      m.seed(:section_definition, "Header", "1^name^string^R\n2^sex^string^R\n3^dob^date^R")
      m.seed(:section_definition, "Address", "1^street^string^O\n2^city^string^O\n3^state^string^O\n4^zip^string^O")
      m.seed(:patient_lock, "1", { lock_id: "LOCK-001" })
      m.seed(:patient_unlock, "1", { success: true })
    end
  end

  def teardown
    RpmsRpc.reset!
  end

  # =============================================================================
  # SECTION DATA (text_blob)
  # =============================================================================

  def test_fetch_section_data_returns_text_for_known_patient
    text = RpmsRpc::DataMapper.section_data.fetch_text("1")

    refute_nil text
    assert_includes text, "DOE,JOHN"
    assert_includes text, "01/15/1980"
  end

  def test_fetch_section_data_returns_multiline_text
    text = RpmsRpc::DataMapper.section_data.fetch_text("1")

    assert_includes text, "NAME:"
    assert_includes text, "SEX:"
    assert_includes text, "DOB:"
  end

  def test_fetch_section_data_returns_nil_for_unknown_patient
    assert_nil RpmsRpc::DataMapper.section_data.fetch_text("99999")
  end

  def test_fetch_section_data_different_patients_return_different_data
    text1 = RpmsRpc::DataMapper.section_data.fetch_text("1")
    text2 = RpmsRpc::DataMapper.section_data.fetch_text("2")

    assert_includes text1, "DOE,JOHN"
    assert_includes text2, "SMITH,JANE"
  end

  # =============================================================================
  # SECTION DEFINITION (text_blob)
  # =============================================================================

  def test_fetch_section_definition_returns_text
    text = RpmsRpc::DataMapper.section_definition.fetch_text("Header")

    refute_nil text
    assert_includes text, "name"
    assert_includes text, "string"
  end

  def test_fetch_section_definition_different_sections
    header = RpmsRpc::DataMapper.section_definition.fetch_text("Header")
    address = RpmsRpc::DataMapper.section_definition.fetch_text("Address")

    assert_includes header, "dob"
    assert_includes address, "street"
    refute_includes header, "street"
  end

  def test_fetch_section_definition_returns_nil_for_unknown
    assert_nil RpmsRpc::DataMapper.section_definition.fetch_text("Nonexistent")
  end

  # =============================================================================
  # PATIENT LOCK
  # =============================================================================

  def test_patient_lock_returns_lock_data
    result = RpmsRpc::DataMapper.patient_lock.fetch_one("1")

    refute_nil result
    assert_equal "LOCK-001", result[:lock_id]
  end

  def test_patient_lock_returns_nil_for_unknown
    assert_nil RpmsRpc::DataMapper.patient_lock.fetch_one("99999")
  end

  # =============================================================================
  # PATIENT UNLOCK
  # =============================================================================

  def test_patient_unlock_returns_data
    result = RpmsRpc::DataMapper.patient_unlock.fetch_one("1")

    refute_nil result
  end
end
