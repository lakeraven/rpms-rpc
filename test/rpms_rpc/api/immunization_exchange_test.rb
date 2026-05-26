# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/immunization_exchange"

class ImmunizationExchangeTest < Minitest::Test
  DFN = 8791

  def setup
    RpmsRpc.mock! do |m|
      m.seed(:immunization_exchange_vxu, DFN.to_s, {
        status_code: 1,
        message: "VXU accepted"
      })

      m.seed(:immunization_exchange_vxq, DFN.to_s, {
        status_code: 1,
        message: "VXQ submitted"
      })

      m.seed_keyed_collection(:immunization_exchange_rsp, DFN.to_s, [
        {
          vaccine_code: "207",
          vaccine_display: "COVID-19 mRNA",
          occurrence_date: Date.new(2026, 5, 1),
          ndc_code: "59267-1000-01",
          status: "completed"
        },
        {
          vaccine_code: "140",
          vaccine_display: "Influenza seasonal",
          occurrence_date: Date.new(2025, 10, 15),
          ndc_code: "49281-0425-10",
          status: nil
        }
      ])

      m.seed(:immunization_exchange_process_result, "", {
        status_code: 1,
        message: "3 responses processed"
      })

      m.seed(:immunization_exchange_status, "", {
        status_code: 1,
        message: "IIS available"
      })
    end
  end

  def teardown
    RpmsRpc.reset!
  end

  def test_send_immunizations_calls_vxu_for_patient
    result = RpmsRpc::ImmunizationExchange.send_immunizations(DFN)

    assert_equal({ success: true, message: "VXU accepted" }, result)
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BYIMRT VXU" }
    refute_nil call
    assert_equal [ DFN.to_s ], call[:params]
  end

  def test_submit_query_calls_vxq_for_patient
    result = RpmsRpc::ImmunizationExchange.submit_query(DFN)

    assert_equal({ success: true, message: "VXQ submitted" }, result)
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BYIMRT VXQ" }
    refute_nil call
    assert_equal [ DFN.to_s ], call[:params]
  end

  def test_write_paths_reject_blank_zero_and_negative_dfn
    [ nil, "", 0, -1, "abc" ].each do |dfn|
      assert_equal({ success: false, message: "Invalid patient DFN" },
        RpmsRpc::ImmunizationExchange.send_immunizations(dfn))
      assert_equal({ success: false, message: "Invalid patient DFN" },
        RpmsRpc::ImmunizationExchange.submit_query(dfn))
    end
  end

  def test_for_patient_returns_immunizations_from_rsp
    immunizations = RpmsRpc::ImmunizationExchange.for_patient(DFN)

    assert_equal 2, immunizations.length
    covid = immunizations.first
    assert_equal "207", covid[:vaccine_code]
    assert_equal "COVID-19 mRNA", covid[:vaccine_display]
    assert_equal Date.new(2026, 5, 1), covid[:occurrence_date]
    assert_equal "59267-1000-01", covid[:ndc_code]
    assert_equal "completed", covid[:status]
  end

  def test_for_patient_defaults_blank_status_to_completed
    immunizations = RpmsRpc::ImmunizationExchange.for_patient(DFN)
    flu = immunizations.find { |i| i[:vaccine_code] == "140" }

    assert_equal "completed", flu[:status]
  end

  def test_for_patient_rejects_blank_zero_negative_and_unknown_dfn
    assert_equal [], RpmsRpc::ImmunizationExchange.for_patient(nil)
    assert_equal [], RpmsRpc::ImmunizationExchange.for_patient("")
    assert_equal [], RpmsRpc::ImmunizationExchange.for_patient(0)
    assert_equal [], RpmsRpc::ImmunizationExchange.for_patient(-1)
    assert_equal [], RpmsRpc::ImmunizationExchange.for_patient("abc")
    assert_equal [], RpmsRpc::ImmunizationExchange.for_patient(999_999)
  end

  def test_retrieve_response_without_dfn_processes_batch_rsp_lines
    RpmsRpc.mock! do |m|
      m.seed_keyed_collection(:immunization_exchange_rsp, "", [
        {
          vaccine_code: "207",
          vaccine_display: "COVID-19 mRNA",
          occurrence_date: Date.new(2026, 5, 1),
          ndc_code: "59267-1000-01",
          status: "completed"
        }
      ])
    end

    result = RpmsRpc::ImmunizationExchange.retrieve_response

    assert_kind_of Array, result
    assert_equal 1, result.length
    assert_equal "COVID-19 mRNA", result.first[:vaccine_display]
  end

  def test_process_responses_extracts_processed_count
    assert_equal({ success: true, count: 3 }, RpmsRpc::ImmunizationExchange.process_responses)
  end

  def test_check_status_returns_available
    assert_equal({ available: true }, RpmsRpc::ImmunizationExchange.check_status)
  end

  def test_status_failures_include_message
    RpmsRpc.mock! do |m|
      m.seed(:immunization_exchange_status, "", { status_code: -1, message: "IIS unavailable" })
    end

    assert_equal({ available: false, error: "IIS unavailable" },
      RpmsRpc::ImmunizationExchange.check_status)
  end
end
