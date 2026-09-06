# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/registration"

# Tests for RpmsRpc::Registration — patient registration with two lineages
# (rpms-rpc#214):
#
#   * DELEGATION (Agg.available?) — AGG ADD NEW PATIENT / AGG UPDATE PATIENT.
#   * COMPOSITION (no AG package)  — VAFC VOA ADD PATIENT + DDR FileMan.
#
# HRN handling has two modes: :derive_from_dfn (default greenfield, HRN := DFN)
# and :clerk_supplied (legacy passthrough). NO client-side HRN uniqueness in
# either mode. All data below is synthetic (DEMOPATIENT names, 900-series
# pseudo-SSNs).
class RegistrationTest < Minitest::Test
  Reg = RpmsRpc::Registration
  Ddr = RpmsRpc::DdrFileman
  Agg = RpmsRpc::Agg

  ATTRS = {
    name: "DEMOPATIENT,UNA",
    dob: Date.new(1990, 1, 2),
    sex: "F",
    ssn: "900010001",
    station_number: "8994",
    full_icn: "1000000001V123456",
    type: "NON-VETERAN (OTHER)",
    veteran: "N",
    service_connected: "N",
    hrn: "100001",
    location_ien: 5,
    # Completion values are FileMan-INTERNAL (DDR FILER runs UPDATE^DIE with
    # no "E" flag — DDR3.m:15,18): pointer IENs for tribe (^AUTTTRI) and
    # classification (^AUTTBEN), the I/D/C/P set code for eligibility,
    # free text for community.
    tribe: "123",
    classification: "13",
    eligibility_status: "I",
    community: "EXAMPLE COMMUNITY"
  }.freeze

  LOCK_NODE = "^AUPNPAT(42)"

  def setup
    @mock = RpmsRpc.mock!
    Reg.hrn_mode = Reg::HRN_MODE_DERIVE
  end

  def teardown
    Reg.hrn_mode = Reg::HRN_MODE_DERIVE
    RpmsRpc.reset!
  end

  # -- capability gating -----------------------------------------------------

  # Agg.available? probes CIANBRPC CANRUN "AGG ADD NEW PATIENT". Seed "0"
  # (or leave unseeded → mock returns "") to force the composition lineage;
  # seed "1" to force delegation.
  def seed_agg(available:)
    @mock.seed_scalar(:agg_canrun, "AGG ADD NEW PATIENT", available ? "1" : "0")
  end

  # -- composition seeding helpers -------------------------------------------

  def seed_voa(attrs = ATTRS, reply: { status: 1, dfn_or_error: "42" })
    @mock.seed(:voa_add_patient, Reg.voa_param(attrs).to_s, reply)
  end

  def seed_lock(node: LOCK_NODE, ok: true)
    @mock.seed(:ddr_lock_unlock_node, Ddr.lock_param(node: node).to_s, ok)
  end

  def seed_existence(dfn: 42, exists: false)
    key = Ddr.gets_entry_param(file: "9000001", iens: "#{dfn},", fields: ".01").to_s
    text = exists ? "[Data]\n9000001^#{dfn}^.01^#{dfn}^DEMOPATIENT,UNA" : "[ERROR]"
    @mock.seed(:ddr_gets_entry_data, key, text)
  end

  def seed_filer(text: "[Data]\n+1,^42\n+2,^5")
    @mock.seed(:ddr_filer, "ADD", text)
  end

  def seed_composition_happy_path
    seed_agg(available: false)
    seed_voa
    seed_lock
    seed_existence
    seed_filer
  end

  def filer_calls
    @mock.received_calls.select { |c| c[:rpc] == "DDR FILER" }
  end

  def all_filer_rows
    filer_calls.flat_map { |c| c[:params][1].values }
  end

  # -- delegation seeding helpers --------------------------------------------

  def seed_agg_add(dfn: "9", result: "1", message: "")
    reply = "I00010RESULT^T00080MESSAGE^I00010DFN\x1e#{result}^#{message}^#{dfn}\x1e\x1f"
    @mock.seed(:agg_add_patient, Agg::DEFAULT_WINDOW, reply)
  end

  def seed_agg_update(result: "1", error: "")
    reply = "I00010RESULT^T01024ERROR^T01024OTHER_PARMS\x1e#{result}^#{error}^\x1e\x1f"
    @mock.seed(:agg_update_patient, Agg::DEFAULT_WINDOW, reply)
  end

  def agg_calls(rpc)
    @mock.received_calls.select { |c| c[:rpc] == rpc }
  end

  # ==========================================================================
  # VOA param construction
  # ==========================================================================

  def test_voa_param_builds_named_list_in_vafcptad_order
    param = Reg.voa_param(ATTRS)

    assert_equal(
      {
        "PRFCLTY" => "8994",
        "NAME" => "DEMOPATIENT^UNA",
        "GENDER" => "F",
        "DOB" => "01/02/1990",
        "SSN" => "900010001",
        "SRVCNCTD" => "N",
        "TYPE" => "NON-VETERAN (OTHER)",
        "VET" => "N",
        "FULLICN" => "1000000001V123456"
      },
      param
    )
  end

  def test_voa_param_splits_name_at_first_comma_only
    param = Reg.voa_param(ATTRS.merge(name: "DEMOPATIENT,UNA MAE"))

    assert_equal "DEMOPATIENT^UNA MAE", param["NAME"]
  end

  def test_voa_param_accepts_name_pieces
    param = Reg.voa_param(ATTRS.merge(
      name: nil, name_last: "DEMOPATIENT", name_first: "UNA", name_middle: "MAE", name_suffix: "JR"
    ))

    assert_equal "DEMOPATIENT^UNA^MAE^JR", param["NAME"]
  end

  def test_voa_param_allows_blank_ssn_for_pseudo_ssn_path
    param = Reg.voa_param(ATTRS.merge(ssn: nil))

    assert_equal "", param["SSN"]
  end

  def test_voa_param_includes_optional_elements_when_given
    param = Reg.voa_param(ATTRS.merge(
      pob_city: "EXAMPLE CITY", pob_state: "MT", mothers_maiden_name: "DEMOMAIDEN,ONE"
    ))

    assert_equal "EXAMPLE CITY", param["POBCTY"]
    assert_equal "MT", param["POBST"]
    assert_equal "DEMOMAIDEN,ONE", param["MMN"]
  end

  def test_voa_param_rejects_missing_required_field_without_echoing_phi
    err = assert_raises(ArgumentError) { Reg.voa_param(ATTRS.merge(full_icn: nil)) }

    assert_match(/full_icn/, err.message)
    refute_match(/DEMOPATIENT/, err.message)
  end

  def test_voa_param_rejects_caret_in_name_piece
    err = assert_raises(ArgumentError) { Reg.voa_param(ATTRS.merge(name: "DEMO^PATIENT,UNA")) }

    assert_match(/name/, err.message)
    refute_match(/DEMO\^PATIENT/, err.message, "message must not echo the PHI value")
  end

  # ==========================================================================
  # Delegation lineage (AG capsule)
  # ==========================================================================

  def test_register_delegates_to_agg_when_available
    seed_agg(available: true)
    seed_agg_add(dfn: "9")
    seed_agg_update

    result = Reg.register(ATTRS)

    assert result[:success]
    assert_equal 9, result[:dfn]
    assert result[:created]
    assert_equal 1, agg_calls("AGG ADD NEW PATIENT").length, "must call the AGG create RPC"
    assert_empty filer_calls, "delegation must not touch the DDR composition path"
  end

  def test_delegation_add_frames_demographics_as_parms_without_hrn_in_greenfield
    seed_agg(available: true)
    seed_agg_add(dfn: "9")
    seed_agg_update

    Reg.register(ATTRS)

    add = agg_calls("AGG ADD NEW PATIENT").first
    window, dfn, parms = add[:params]
    assert_equal Agg::DEFAULT_WINDOW, window
    assert_equal "", dfn, "new patient => empty DFN"
    pairs = parms.split("\x1c")
    assert_includes pairs, "AGGPTLNM=DEMOPATIENT"
    assert_includes pairs, "AGGPTFNM=UNA"
    assert_includes pairs, "AGGPTSEX=FEMALE"
    assert_includes pairs, "AGGPTDOB=01/02/1990"
    assert_includes pairs, "AGGPTSSN=900010001"
    assert pairs.none? { |p| p.start_with?("AGGPTHRN=") },
           "greenfield must NOT send a clerk HRN on the create call"
  end

  def test_delegation_greenfield_files_hrn_equal_to_dfn_via_update
    seed_agg(available: true)
    seed_agg_add(dfn: "9")
    seed_agg_update

    Reg.register(ATTRS)

    upd = agg_calls("AGG UPDATE PATIENT").first
    refute_nil upd, "greenfield HRN := DFN is filed through the AGG update path"
    _window, dfn, parms = upd[:params]
    assert_equal "9", dfn
    assert_equal "AGGPTHRN=9", parms, "HRN must equal the server-assigned DFN"
  end

  def test_delegation_clerk_mode_sends_supplied_hrn_on_create_and_skips_update
    Reg.hrn_mode = Reg::HRN_MODE_CLERK
    seed_agg(available: true)
    seed_agg_add(dfn: "9")

    result = Reg.register(ATTRS)

    assert result[:success]
    add = agg_calls("AGG ADD NEW PATIENT").first
    assert_includes add[:params][2].split("\x1c"), "AGGPTHRN=100001"
    assert_empty agg_calls("AGG UPDATE PATIENT"),
                 "clerk-supplied HRN rides the create call — no HRN:=DFN update"
  end

  def test_delegation_surfaces_agg_rejection
    seed_agg(available: true)
    seed_agg_add(result: "-1", message: "MISSING MANDATORY FIELD", dfn: "")

    result = Reg.register(ATTRS)

    refute result[:success]
    assert_equal :agg_rejected, result[:error]
    assert_match(/MANDATORY/, result[:message])
    assert_empty agg_calls("AGG UPDATE PATIENT"), "no HRN update after a failed create"
  end

  def test_delegation_hrn_update_failure_surfaces_with_dfn
    seed_agg(available: true)
    seed_agg_add(dfn: "9")
    seed_agg_update(result: "-1", error: "HRN FIELD REJECTED")

    result = Reg.register(ATTRS)

    refute result[:success]
    assert_equal :hrn_file_failed, result[:error]
    assert_equal 9, result[:dfn], "the patient was created; surface the DFN for retry"
  end

  # ==========================================================================
  # Composition lineage — greenfield happy path (HRN := DFN)
  # ==========================================================================

  def test_register_success_returns_dfn_and_created
    seed_composition_happy_path

    result = Reg.register(ATTRS)

    assert result[:success]
    assert_equal 42, result[:dfn]
    assert result[:created]
  end

  def test_register_files_stub_then_hrn_and_ihs_fields_in_two_filer_passes
    seed_composition_happy_path

    Reg.register(ATTRS)

    stub, completion = filer_calls.map { |c| c[:params] }
    refute_nil completion, "expected two DDR FILER passes (stub + completion)"
    # Pass 1 — #9000001 .01 stub filed at the DINUM IEN = DFN.
    assert_equal [ "ADD", { 1 => "9000001^.01^+1,^42" }, "", { 1 => "42" } ], stub
    # Pass 2 — greenfield HRN := DFN (42) rides the 41 multiple; then the IHS
    # completion fields (1108/1111/1112/1118).
    mode, root, flags, iens = completion
    assert_equal "ADD", mode
    assert_equal "", flags
    assert_equal "9000001.41^.01^+1,42,^5", root[1]
    assert_equal "9000001.41^.02^+1,42,^42", root[2]
    assert_equal "9000001^1108^42,^123", root[3]
    assert_equal "9000001^1111^42,^13", root[4]
    assert_equal "9000001^1112^42,^I", root[5]
    assert_equal "9000001^1118^42,^EXAMPLE COMMUNITY", root[6]
    assert_equal({ 1 => "5" }, iens)
  end

  def test_composition_clerk_mode_files_supplied_hrn
    Reg.hrn_mode = Reg::HRN_MODE_CLERK
    seed_composition_happy_path

    Reg.register(ATTRS)

    assert_includes all_filer_rows, "9000001.41^.02^+1,42,^100001",
                    "clerk-supplied mode files the caller HRN verbatim"
  end

  def test_register_locks_then_unlocks_aupnpat_node
    seed_composition_happy_path

    Reg.register(ATTRS)

    lock_calls = @mock.received_calls.select { |c| c[:rpc] == "DDR LOCK/UNLOCK NODE" }
    assert_equal [ Ddr.lock_param(node: LOCK_NODE), Ddr.unlock_param(node: LOCK_NODE) ],
                 lock_calls.map { |c| c[:params].first }
  end

  def test_register_does_no_client_side_hrn_uniqueness_lister_precheck
    seed_composition_happy_path

    Reg.register(ATTRS)

    assert_nil @mock.received_calls.find { |c| c[:rpc] == "DDR LISTER" },
               "no client-side HRN uniqueness pre-check (#214)"
  end

  def test_register_supports_extra_fields_escape_hatch
    seed_composition_happy_path

    Reg.register(ATTRS.merge(extra_fields: [ { field: "1110", value: "4/4" } ]))

    assert_includes all_filer_rows, "9000001^1110^42,^4/4"
  end

  # ==========================================================================
  # Composition — idempotent re-run (safe after partial failure)
  # ==========================================================================

  def test_register_rerun_with_existing_record_skips_stub_and_hrn_rows
    seed_agg(available: false)
    seed_voa # VOA returns the existing DFN for a known ICN (VAFCPTAD.m:55)
    seed_lock
    seed_existence(exists: true)
    seed_filer(text: "[Data]")

    result = Reg.register(ATTRS)

    assert result[:success]
    assert_equal 42, result[:dfn]
    refute result[:created]
    # No stub pass, no 41-multiple rows — only field edits against "42,".
    assert_equal 1, filer_calls.length
    refute_includes all_filer_rows, "9000001^.01^+1,^42"
    assert all_filer_rows.none? { |r| r.start_with?("9000001.41^") }
    assert_includes all_filer_rows, "9000001^1108^42,^123"
  end

  def test_register_rerun_with_nothing_left_to_file_skips_filer
    attrs = ATTRS.reject { |k, _| %i[tribe classification eligibility_status community].include?(k) }
    seed_agg(available: false)
    seed_voa(attrs)
    seed_lock
    seed_existence(exists: true)

    result = Reg.register(attrs)

    assert result[:success]
    refute result[:created]
    assert_empty filer_calls, "no DDR FILER call expected when everything is already filed"
  end

  # ==========================================================================
  # Composition — error taxonomy
  # ==========================================================================

  def test_register_voa_rejection_returns_error_with_message
    seed_agg(available: false)
    seed_voa(reply: { status: -1, dfn_or_error: "PREFERRED FACILITY is a required field." })

    result = Reg.register(ATTRS)

    refute result[:success]
    assert_equal :voa_rejected, result[:error]
    assert_match(/PREFERRED FACILITY/, result[:message])
    ddr = @mock.received_calls.select { |c| c[:rpc].start_with?("DDR ") }
    assert_empty ddr, "no DDR call may follow a VOA rejection"
  end

  def test_register_classifies_duplicate_identity
    seed_agg(available: false)
    seed_voa(reply: { status: -1, dfn_or_error: "Patient already exists" })

    result = Reg.register(ATTRS)

    assert_equal :duplicate_identity, result[:error]
  end

  def test_register_lock_failure_stops_before_filing
    seed_agg(available: false)
    seed_voa
    seed_lock(ok: false)

    result = Reg.register(ATTRS)

    refute result[:success]
    assert_equal :lock_failed, result[:error]
    assert_empty filer_calls
    unlocks = @mock.received_calls.select do |c|
      c[:rpc] == "DDR LOCK/UNLOCK NODE" && c[:params].first == Ddr.unlock_param(node: LOCK_NODE)
    end
    assert_empty unlocks, "must not unlock a node it never locked"
  end

  def test_register_filer_rejection_surfaces_fileman_error_text
    seed_agg(available: false)
    seed_voa
    seed_lock
    seed_existence
    seed_filer(text: "[BEGIN_diERRORS]\n701^1^9000001^+1,^.01^0\nThe value is not valid.\n[END_diERRORS]")

    result = Reg.register(ATTRS)

    refute result[:success]
    assert_equal :filer_rejected, result[:error]
    assert_match(/not valid/, result[:message])
  end

  def test_register_unlocks_even_when_filer_rejects
    seed_agg(available: false)
    seed_voa
    seed_lock
    seed_existence
    seed_filer(text: "[BEGIN_diERRORS]\n701^1^9000001^+1,^.01^0\nBad.\n[END_diERRORS]")

    Reg.register(ATTRS)

    unlock = @mock.received_calls.last
    assert_equal "DDR LOCK/UNLOCK NODE", unlock[:rpc]
    assert_equal Ddr.unlock_param(node: LOCK_NODE), unlock[:params].first
  end

  def test_register_returns_nil_when_broker_gives_no_response
    seed_agg(available: false)
    # Nothing else seeded — the mock returns "" for the VOA call.
    assert_nil Reg.register(ATTRS)
  end

  # ==========================================================================
  # UPDATE — composed edit path (DDR FILER / FILE^DIE under the ^DPT lock;
  # EDIT^VAFCPTED has no ^XWB(8994) registration on any observed target)
  # ==========================================================================

  def seed_update_lock(dfn: 42, ok: true)
    @mock.seed(:ddr_lock_unlock_node, Ddr.lock_param(node: "^DPT(#{dfn})").to_s, ok)
  end

  def test_update_files_both_halves_through_one_edit_pass
    seed_update_lock
    @mock.seed(:ddr_filer, "EDIT", "[Data]")

    result = Reg.update(42,
      patient_fields: { ".111" => "123 EXAMPLE ST" },
      ihs_fields: { "1118" => "EXAMPLE COMMUNITY" })

    assert result[:success]
    assert_equal 42, result[:dfn]
    filer = filer_calls.last
    assert_equal "EDIT", filer[:params][0]
    assert_equal [ "2^.111^42,^123 EXAMPLE ST", "9000001^1118^42,^EXAMPLE COMMUNITY" ],
                 filer[:params][1].values
  end

  def test_update_fails_and_skips_filer_when_dpt_lock_unavailable
    seed_update_lock(ok: false)

    result = Reg.update(42, patient_fields: { ".111" => "123 EXAMPLE ST" })

    refute result[:success]
    assert_equal :lock_failed, result[:error]
    assert_empty filer_calls
  end

  def test_update_surfaces_filer_rejection_and_still_unlocks
    seed_update_lock
    @mock.seed(:ddr_filer, "EDIT",
      "[BEGIN_diERRORS]\n701^1^2^42,^.111^0\nThe value is not valid.\n[END_diERRORS]")

    result = Reg.update(42, patient_fields: { ".111" => "" })

    refute result[:success]
    assert_equal :filer_rejected, result[:error]
    unlock = @mock.received_calls.last
    assert_equal "DDR LOCK/UNLOCK NODE", unlock[:rpc]
    assert_equal Ddr.unlock_param(node: "^DPT(42)"), unlock[:params].first
  end

  def test_update_rejects_invalid_dfn_and_empty_field_set
    assert_equal :invalid_dfn, Reg.update(0, patient_fields: { ".111" => "X" })[:error]
    assert_equal :no_fields, Reg.update(42)[:error]
    assert_empty @mock.received_calls
  end
end
