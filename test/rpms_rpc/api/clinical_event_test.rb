# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/version"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/clinical_event"

class ClinicalEventTest < Minitest::Test
  VISIT_IEN = "7001"
  EVENT_IEN = "9100"
  DFN = "8791"

  def teardown
    RpmsRpc.reset!
  end

  # -- Reads ----------------------------------------------------------------

  def test_get_visit_returns_visit_row
    RpmsRpc.mock! do |m|
      m.seed_capability(:orwpce_pce_workflow, supported: true)
      m.seed_keyed_collection(:pce_get_visit, VISIT_IEN, [
        { ien: VISIT_IEN, location: "PCH", provider: "DOE,JANE" }
      ])
    end

    row = RpmsRpc::ClinicalEvent.get_visit(VISIT_IEN)

    refute_nil row
    assert_equal VISIT_IEN, row[:ien]
    assert_equal "PCH", row[:location]
  end

  def test_get_visit_returns_nil_when_unsupported
    RpmsRpc.mock! do |m|
      m.seed_capability(:orwpce_pce_workflow, supported: false)
    end

    assert_nil RpmsRpc::ClinicalEvent.get_visit(VISIT_IEN)
  end

  def test_get_visit_returns_nil_for_invalid_visit
    RpmsRpc.mock! do |m|
      m.seed_capability(:orwpce_pce_workflow, supported: true)
    end

    assert_nil RpmsRpc::ClinicalEvent.get_visit(nil)
    assert_nil RpmsRpc::ClinicalEvent.get_visit("0")
  end

  def test_health_factor_types_dispatches_orwpce_get_health_factors_ty
    RpmsRpc.mock! do |m|
      m.seed_capability(:orwpce_pce_workflow, supported: true)
      m.seed_collection(:pce_health_factor_types, [
        { ien: "1", name: "Smoker", category: "TOBACCO" }
      ])
    end

    rows = RpmsRpc::ClinicalEvent.health_factor_types

    assert_equal 1, rows.length
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWPCE GET HEALTH FACTORS TY" }
    refute_nil call
  end

  def test_health_factor_types_short_circuits_when_unsupported
    RpmsRpc.mock! do |m|
      m.seed_capability(:orwpce_pce_workflow, supported: false)
    end

    assert_equal [], RpmsRpc::ClinicalEvent.health_factor_types
  end

  def test_active_problems_dispatches_orwpce_actprob_with_dfn
    RpmsRpc.mock! do |m|
      m.seed_capability(:orwpce_pce_workflow, supported: true)
      m.seed_keyed_collection(:pce_active_problems, DFN, [
        { ien: "5001", description: "HTN", icd_code: "I10" }
      ])
    end

    rows = RpmsRpc::ClinicalEvent.active_problems(DFN)

    assert_equal 1, rows.length
    assert_equal "HTN", rows.first[:description]
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWPCE ACTPROB" }
    refute_nil call
    assert_equal [ DFN ], call[:params]
  end

  def test_set_of_codes_returns_empty_for_blank_set_name
    RpmsRpc.mock! do |m|
      m.seed_capability(:orwpce_pce_workflow, supported: true)
    end

    assert_equal [], RpmsRpc::ClinicalEvent.set_of_codes("")
    assert_equal [], RpmsRpc::ClinicalEvent.set_of_codes("   ")
  end

  # -- Writes ---------------------------------------------------------------

  def test_save_success_via_orwpce_save
    RpmsRpc.mock! do |m|
      m.seed_capability(:orwpce_pce_workflow, supported: true)
      m.seed_scalar(:pce_save, VISIT_IEN, "1^SAVED")
    end

    result = RpmsRpc::ClinicalEvent.save(VISIT_IEN, "PAYLOAD")

    assert result[:success]
    assert_equal "SAVED", result[:message]
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWPCE SAVE" }
    refute_nil call
    assert_equal [ VISIT_IEN, "PAYLOAD" ], call[:params]
  end

  def test_save_bare_ien_response_preserves_value
    # Defensive: ORWPCE SAVE returning a bare IEN must not be parsed as "0".
    # Mirrors PR #157 lesson.
    RpmsRpc.mock! do |m|
      m.seed_capability(:orwpce_pce_workflow, supported: true)
      m.seed_scalar(:pce_save, VISIT_IEN, "10")
    end

    result = RpmsRpc::ClinicalEvent.save(VISIT_IEN, "PAYLOAD")

    assert result[:success]
    assert_equal "10", result[:message]
  end

  def test_save_failure_response
    RpmsRpc.mock! do |m|
      m.seed_capability(:orwpce_pce_workflow, supported: true)
      m.seed_scalar(:pce_save, VISIT_IEN, "0^visit not editable")
    end

    result = RpmsRpc::ClinicalEvent.save(VISIT_IEN, "PAYLOAD")

    refute result[:success]
    assert_equal "visit not editable", result[:message]
  end

  def test_save_short_circuits_when_unsupported
    RpmsRpc.mock! do |m|
      m.seed_capability(:orwpce_pce_workflow, supported: false)
    end

    result = RpmsRpc::ClinicalEvent.save(VISIT_IEN, "PAYLOAD")

    refute result[:success]
    assert_match(/not available/, result[:error])
  end

  def test_save_rejects_blank_payload_with_validation_error
    RpmsRpc.mock! do |m|
      m.seed_capability(:orwpce_pce_workflow, supported: true)
    end

    result = RpmsRpc::ClinicalEvent.save(VISIT_IEN, "")

    refute result[:success]
    assert_match(/payload required/, result[:error])
    refute_match(/workflow not available/, result[:error],
                 "blank payload on supported server must not report capability failure")
  end

  def test_save_rejects_invalid_visit_with_validation_error
    RpmsRpc.mock! do |m|
      m.seed_capability(:orwpce_pce_workflow, supported: true)
    end

    result = RpmsRpc::ClinicalEvent.save("0", "PAYLOAD")

    refute result[:success]
    assert_match(/invalid visit_ien/, result[:error])
  end

  def test_delete_rejects_invalid_ids_with_validation_error
    RpmsRpc.mock! do |m|
      m.seed_capability(:orwpce_pce_workflow, supported: true)
    end

    result = RpmsRpc::ClinicalEvent.delete("0", EVENT_IEN)
    refute result[:success]
    assert_match(/invalid visit_ien/, result[:error])

    result = RpmsRpc::ClinicalEvent.delete(VISIT_IEN, "0")
    refute result[:success]
    assert_match(/invalid event_ien/, result[:error])
  end

  def test_force_rejects_invalid_visit_with_validation_error
    RpmsRpc.mock! do |m|
      m.seed_capability(:orwpce_pce_workflow, supported: true)
    end

    result = RpmsRpc::ClinicalEvent.force("0")

    refute result[:success]
    assert_match(/invalid visit_ien/, result[:error])
  end

  def test_delete_dispatches_orwpce_delete
    RpmsRpc.mock! do |m|
      m.seed_capability(:orwpce_pce_workflow, supported: true)
      m.seed_scalar(:pce_delete, VISIT_IEN, "1")
    end

    result = RpmsRpc::ClinicalEvent.delete(VISIT_IEN, EVENT_IEN)

    assert result[:success]
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWPCE DELETE" }
    refute_nil call
    assert_equal [ VISIT_IEN, EVENT_IEN ], call[:params]
  end

  def test_force_dispatches_orwpce_force
    RpmsRpc.mock! do |m|
      m.seed_capability(:orwpce_pce_workflow, supported: true)
      m.seed_scalar(:pce_force, VISIT_IEN, "1")
    end

    result = RpmsRpc::ClinicalEvent.force(VISIT_IEN)

    assert result[:success]
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWPCE FORCE" }
    refute_nil call
  end

  # -- Encounter wiring -----------------------------------------------------

  def test_ask_pce_returns_scalar_value
    RpmsRpc.mock! do |m|
      m.seed_capability(:orwpce_pce_workflow, supported: true)
      m.seed_scalar(:pce_ask_pce, VISIT_IEN, "1")
    end

    assert_equal "1", RpmsRpc::ClinicalEvent.ask_pce(VISIT_IEN)
  end

  def test_for_note_dispatches_orwpce_pce4note
    RpmsRpc.mock! do |m|
      m.seed_capability(:orwpce_pce_workflow, supported: true)
      m.seed_keyed_collection(:pce_for_note, "12345", [
        { event_type: "HF", description: "Smoker counseled" }
      ])
    end

    rows = RpmsRpc::ClinicalEvent.for_note("12345")

    assert_equal 1, rows.length
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWPCE PCE4NOTE" }
    refute_nil call
  end

  def test_note_visit_string_returns_scalar
    RpmsRpc.mock! do |m|
      m.seed_capability(:orwpce_pce_workflow, supported: true)
      m.seed_scalar(:pce_note_visit_string, "12345", "PCH;1234567")
    end

    assert_equal "PCH;1234567", RpmsRpc::ClinicalEvent.note_visit_string("12345")
  end

  def test_note_visit_string_short_circuits_when_unsupported
    RpmsRpc.mock! do |m|
      m.seed_capability(:orwpce_pce_workflow, supported: false)
    end

    assert_nil RpmsRpc::ClinicalEvent.note_visit_string("12345")
  end

  # -- Compact dispatch + gating coverage for remaining read helpers --------

  TYPE_LOOKUPS = {
    exam_types:         { mapping: :pce_exam_types,         rpc: "ORWPCE GET EXAM TYPE",         row: { ien: "1", name: "Hearing" } },
    immunization_types: { mapping: :pce_immunization_types, rpc: "ORWPCE GET IMMUNIZATION TYPE", row: { ien: "1", name: "Influenza" } },
    skin_test_types:    { mapping: :pce_skin_test_types,    rpc: "ORWPCE GET SKIN TEST TYPE",    row: { ien: "1", name: "PPD" } },
    treatment_types:    { mapping: :pce_treatment_types,    rpc: "ORWPCE GET TREATMENT TYPE",    row: { ien: "1", name: "Dressing" } },
    education_topics:   { mapping: :pce_education_topics,   rpc: "ORWPCE GET EDUCATION TOPICS",  row: { ien: "1", name: "Smoking" } },
    excluded:           { mapping: :pce_excluded,           rpc: "ORWPCE GET EXCLUDED",          row: { code: "X", display: "Excluded" } },
    active_codes:       { mapping: :pce_active_codes,       rpc: "ORWPCE ACTIVE CODE",           row: { code: "A", display: "Active" } },
    active_providers:   { mapping: :pce_active_providers,   rpc: "ORWPCE ACTIVE PROV",           row: { duz: "10", name: "DOE,JANE" } }
  }.freeze

  TYPE_LOOKUPS.each do |method, spec|
    define_method("test_#{method}_dispatches_#{spec[:mapping]}") do
      RpmsRpc.mock! do |m|
        m.seed_capability(:orwpce_pce_workflow, supported: true)
        m.seed_collection(spec[:mapping], [ spec[:row] ])
      end

      rows = RpmsRpc::ClinicalEvent.public_send(method)

      assert_equal 1, rows.length
      call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == spec[:rpc] }
      refute_nil call, "Expected #{spec[:rpc]} to be dispatched"
    end

    define_method("test_#{method}_returns_empty_when_unsupported") do
      RpmsRpc.mock! do |m|
        m.seed_capability(:orwpce_pce_workflow, supported: false)
      end

      assert_equal [], RpmsRpc::ClinicalEvent.public_send(method)
    end
  end

  def test_anytime_dispatches_orwpce_anytime
    RpmsRpc.mock! do |m|
      m.seed_capability(:orwpce_pce_workflow, supported: true)
      m.seed_scalar(:pce_anytime, "", "1")
    end

    answer = RpmsRpc::ClinicalEvent.anytime

    assert_equal "1", answer
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWPCE ANYTIME" }
    refute_nil call
  end

  def test_anytime_returns_nil_when_unsupported
    RpmsRpc.mock! do |m|
      m.seed_capability(:orwpce_pce_workflow, supported: false)
    end

    assert_nil RpmsRpc::ClinicalEvent.anytime
  end
end
