# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/immunization"

class ImmunizationTest < Minitest::Test
  DFN = "8791"

  def teardown
    RpmsRpc.reset!
  end

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

  def test_text_summary_returns_nil_for_invalid_dfn
    assert_nil RpmsRpc::Immunization.text_summary(nil)
    assert_nil RpmsRpc::Immunization.text_summary("")
    assert_nil RpmsRpc::Immunization.text_summary("0")
  end
end
