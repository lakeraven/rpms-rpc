# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/version"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/immunization"

class ImmunizationTest < Minitest::Test
  DFN = "8791"
  IMM_IEN = "7001"

  SEEDED_RECORD = {
    ien: 7001,
    vaccine_code: "207",
    vaccine_display: "COVID-19 Pfizer-BioNTech, mRNA",
    status: "completed",
    lot_number: "EX1234",
    expiration_date: Date.new(2026, 12, 31),
    site: "Left deltoid",
    route: "IM",
    performer_duz: "301",
    performer_name: "MARTINEZ,SARAH",
    occurrence_datetime: Time.utc(2026, 1, 15, 10, 0, 0),
    dose_quantity: 0.3,
    dose_unit: "mL",
    manufacturer: "Pfizer-BioNTech",
    vfc_eligibility_code: "V04",
    funding_source: "VFC"
  }.freeze

  def teardown
    RpmsRpc.reset!
  end

  # --- for_patient ---

  def test_for_patient_returns_array_of_structured_records
    RpmsRpc.mock! do |m|
      m.seed_keyed_collection(:immunization_list, DFN, [ SEEDED_RECORD ])
    end

    result = RpmsRpc::Immunization.for_patient(DFN)

    assert_kind_of Array, result
    assert_equal 1, result.length
    assert_equal "207", result.first[:vaccine_code]
    assert_equal "EX1234", result.first[:lot_number]
    assert_equal "V04", result.first[:vfc_eligibility_code]
  end

  def test_for_patient_dispatches_bipc_immlist_with_dfn
    RpmsRpc.mock! do |m|
      m.seed_keyed_collection(:immunization_list, DFN, [])
    end

    RpmsRpc::Immunization.for_patient(DFN)

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BIPC IMMLIST" }
    refute_nil call, "expected BIPC IMMLIST to be dispatched"
    assert_equal [ DFN ], call[:params]
  end

  def test_for_patient_returns_empty_for_invalid_dfn
    assert_equal [], RpmsRpc::Immunization.for_patient(nil)
    assert_equal [], RpmsRpc::Immunization.for_patient("")
    assert_equal [], RpmsRpc::Immunization.for_patient("0")
  end

  # --- find ---

  def test_find_returns_a_single_structured_record
    RpmsRpc.mock! do |m|
      m.seed(:immunization_detail, IMM_IEN, SEEDED_RECORD)
    end

    result = RpmsRpc::Immunization.find(IMM_IEN)

    assert_kind_of Hash, result
    assert_equal "207", result[:vaccine_code]
    assert_equal "Pfizer-BioNTech", result[:manufacturer]
  end

  def test_find_dispatches_bipc_immget_with_ien
    RpmsRpc.mock! do |m|
      m.seed(:immunization_detail, IMM_IEN, SEEDED_RECORD)
    end

    RpmsRpc::Immunization.find(IMM_IEN)

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BIPC IMMGET" }
    refute_nil call, "expected BIPC IMMGET to be dispatched"
    assert_equal [ IMM_IEN ], call[:params]
  end

  def test_find_returns_nil_for_invalid_ien
    assert_nil RpmsRpc::Immunization.find(nil)
    assert_nil RpmsRpc::Immunization.find("")
    assert_nil RpmsRpc::Immunization.find("0")
  end

  def test_find_returns_nil_when_no_record_exists
    RpmsRpc.mock! do |m|
      m.seed(:immunization_detail, IMM_IEN, SEEDED_RECORD) # other record exists; the one we ask for doesn't
    end

    assert_nil RpmsRpc::Immunization.find("999999")
  end

  # --- text_summary (preserves old BEHOCIR GETTXT behavior) ---

  def test_text_summary_returns_the_patient_summary_text_blob
    summary = "PATIENT IMMUNIZATIONS:\n  2026-01-15 COVID-19 Pfizer EX1234\n"
    RpmsRpc.mock! do |m|
      m.seed_text(:immunization_text, DFN, summary)
    end

    text = RpmsRpc::Immunization.text_summary(DFN)
    flattened = Array(text).join("\n")
    assert_includes flattened, "COVID-19 Pfizer EX1234"
  end

  def test_text_summary_dispatches_behocir_gettxt
    RpmsRpc.mock! { |m| m.seed_text(:immunization_text, DFN, "") }

    RpmsRpc::Immunization.text_summary(DFN)

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BEHOCIR GETTXT" }
    refute_nil call, "expected BEHOCIR GETTXT to be dispatched"
    assert_equal [ DFN ], call[:params]
  end
end
