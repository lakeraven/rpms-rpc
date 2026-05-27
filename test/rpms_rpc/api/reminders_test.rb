# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc/version"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/reminders"

class RemindersTest < Minitest::Test
  PATIENT_DFN = "8791"
  VISIT_IEN   = "12345"
  DUE_DATE    = Date.today + 14

  def setup
    RpmsRpc.mock! do |m|
      m.seed_keyed_collection(:reminder_summary, PATIENT_DFN, [
        { id: 1001, name: "Diabetic Foot Exam", status_code: "DUE",        priority: 1, due_date: DUE_DATE },
        { id: 1002, name: "Influenza Vaccine",  status_code: "APPLICABLE", priority: 2, due_date: nil },
        { id: 1003, name: "Mammogram",          status_code: "SATISFIED",  priority: 3, due_date: nil }
      ])
    end
  end

  def teardown
    RpmsRpc.reset!
  end

  def test_for_visit_returns_documented_shape
    rows = RpmsRpc::Reminders.for_visit(PATIENT_DFN, VISIT_IEN)

    assert_equal 3, rows.length
    first = rows.first
    assert_equal 1001, first[:id]
    assert_equal "Diabetic Foot Exam", first[:name]
    assert_equal :due, first[:status]
    assert_equal 1, first[:priority]
    assert_equal DUE_DATE, first[:due_date]
  end

  def test_for_visit_maps_status_codes_to_taxonomy_symbols
    rows = RpmsRpc::Reminders.for_visit(PATIENT_DFN, VISIT_IEN)
    statuses = rows.map { |r| r[:status] }

    assert_equal [ :due, :applicable, :satisfied ], statuses
  end

  def test_for_visit_dispatches_bgotrg_getsum
    RpmsRpc::Reminders.for_visit(PATIENT_DFN, VISIT_IEN)

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BGOTRG GETSUM" }
    refute_nil call
    assert_equal [ PATIENT_DFN, VISIT_IEN ], call[:params]
  end

  def test_for_visit_returns_empty_for_blank_args
    assert_equal [], RpmsRpc::Reminders.for_visit(nil, VISIT_IEN)
    assert_equal [], RpmsRpc::Reminders.for_visit(PATIENT_DFN, nil)
    assert_equal [], RpmsRpc::Reminders.for_visit("", "")
    assert_equal [], RpmsRpc::Reminders.for_visit("0", "0")
  end

  def test_for_visit_returns_empty_when_no_reminders_seeded
    RpmsRpc.mock!
    assert_equal [], RpmsRpc::Reminders.for_visit(PATIENT_DFN, VISIT_IEN)
  end

  def test_unknown_status_code_falls_back_to_symbol
    RpmsRpc.mock! do |m|
      m.seed_keyed_collection(:reminder_summary, PATIENT_DFN, [
        { id: 2001, name: "Unknown State", status_code: "FROZEN", priority: 1, due_date: nil }
      ])
    end

    rows = RpmsRpc::Reminders.for_visit(PATIENT_DFN, VISIT_IEN)
    assert_equal :frozen, rows.first[:status]
  end

  def test_blank_status_code_yields_nil_not_empty_symbol
    RpmsRpc.mock! do |m|
      m.seed_keyed_collection(:reminder_summary, PATIENT_DFN, [
        { id: 3001, name: "Missing State", status_code: "", priority: 1, due_date: nil }
      ])
    end

    rows = RpmsRpc::Reminders.for_visit(PATIENT_DFN, VISIT_IEN)
    assert_nil rows.first[:status]
  end
end
