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

  # The identity guard reads ORWPT ID INFO for the DFN that VOA resolved.
  # The default seed matches ATTRS so the guard passes; pass explicit pieces
  # to force a mismatch. Live shape: ssn^dob(FileMan)^sex^race^^site^^name
  # (stock_vista.rb :patient_id_info).
  def seed_identity(dfn: 42, ssn: "900010001", dob: "2900102", sex: "F",
                    name: "DEMOPATIENT,UNA")
    @mock.seed(:patient_id_info, dfn.to_s,
      { ssn: ssn, dob: dob, sex: sex, name: name })
  end

  def seed_composition_happy_path
    seed_agg(available: false)
    seed_voa
    seed_identity
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

  # rpms-rpc#225: the delegation decision is only meaningful under AGGRPC. The
  # AGG* RPCs are registered to that option alone, so probing under whatever
  # context the session happens to hold answers a truthful 0 — which reads as
  # "AG is not installed" and drops every registration into the composition
  # path, skipping the AG capsule's HL7/MPI staging and ^AGPATCH stamp.
  def test_register_asks_the_delegation_question_under_the_agg_context
    seed_agg(available: true)
    seed_agg_add(dfn: "9")
    seed_agg_update

    Reg.register(ATTRS)

    gate = @mock.received_calls.find { |c| c[:rpc] == "CIANBRPC CANRUN" }

    assert_equal "AGGRPC", gate[:context], "the gate must be asked where AGG* is registered"
    agg_calls("AGG ADD NEW PATIENT").each do |c|
      assert_equal "AGGRPC", c[:context], "and the writes must run there too"
    end
  end

  def test_composition_path_does_not_bind_the_agg_context_for_its_own_calls
    seed_composition_happy_path

    Reg.register(ATTRS)

    filer_calls.each do |c|
      refute_equal "AGGRPC", c[:context],
        "the VOA + DDR floor must not inherit the probe's context"
    end
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

  # ==========================================================================
  # Identity guard — VOA ADD PATIENT returns "1^DFN" both for a freshly created
  # patient AND for an ICN that already exists at this facility
  # (VAFCPTAD.m:29,55), with NO identity re-validation. Without a guard, an ICN
  # collision files this request's demographics onto ANOTHER person's chart.
  # Salvaged from #187 (BLOCKER-3), which predates the AGG delegation split.
  # ==========================================================================

  def test_register_aborts_on_identity_mismatch_before_any_write
    seed_agg(available: false)
    seed_voa # resolves to DFN 42
    # ORWPT ID INFO returns a DIFFERENT person (wrong-patient ICN collision).
    seed_identity(sex: "M", name: "OTHERPATIENT,ZED", dob: "2800315")
    seed_lock
    seed_existence
    seed_filer

    result = Reg.register(ATTRS)

    refute result[:success]
    assert_equal :identity_mismatch, result[:error]
    assert_match(/does not match/, result[:message])
    refute_match(/DEMOPATIENT|OTHERPATIENT/, result[:message], "message must not echo PHI")
    # The guard runs BEFORE the write path: no lock, no filing.
    assert_empty @mock.received_calls.select { |c| c[:rpc] == "DDR LOCK/UNLOCK NODE" }
    assert_empty filer_calls
  end

  def test_register_proceeds_when_identity_matches
    seed_composition_happy_path # seed_identity matches ATTRS

    result = Reg.register(ATTRS)

    assert result[:success]
    assert_equal 42, result[:dfn]
  end

  # Unverifiable is NOT mismatched: ORWPT ID INFO returning nothing (capability
  # gap, or a record too fresh to read back) must not false-reject a valid
  # registration. Absence of data is not evidence of a collision.
  def test_register_proceeds_when_identity_unverifiable
    seed_agg(available: false)
    seed_voa
    seed_lock
    seed_existence
    seed_filer

    result = Reg.register(ATTRS) # no seed_identity

    assert result[:success]
  end

  # A single diverging field is enough, and the message names WHICH field
  # diverged without echoing either value.
  def test_register_rejects_on_sex_mismatch_alone
    seed_agg(available: false)
    seed_voa
    seed_identity(sex: "M") # name and DOB still match
    seed_lock
    seed_existence
    seed_filer

    result = Reg.register(ATTRS)

    assert_equal :identity_mismatch, result[:error]
    assert_match(/sex/, result[:message])
  end

  def test_register_rejects_on_last_name_mismatch_alone
    seed_agg(available: false)
    seed_voa
    seed_identity(name: "OTHERPATIENT,UNA") # sex and DOB still match
    seed_lock
    seed_existence
    seed_filer

    result = Reg.register(ATTRS)

    assert_equal :identity_mismatch, result[:error]
    assert_match(/last_name/, result[:message])
    assert_empty filer_calls
  end

  def test_register_rejects_on_dob_mismatch_alone
    seed_agg(available: false)
    seed_voa
    seed_identity(dob: "2800315") # name and sex still match
    seed_lock
    seed_existence
    seed_filer

    result = Reg.register(ATTRS)

    assert_equal :identity_mismatch, result[:error]
    assert_match(/dob/, result[:message])
    assert_empty filer_calls
  end

  # Same last name, different first name is NOT a mismatch: the guard compares
  # last-name tokens only, because VAFCPTAD reassembles "LAST,FIRST MIDDLE" and
  # the first-name half does not round-trip reliably.
  def test_register_proceeds_when_only_the_first_name_differs
    seed_agg(available: false)
    seed_voa
    seed_identity(name: "DEMOPATIENT,OTHERFIRST")
    seed_lock
    seed_existence
    seed_filer

    assert Reg.register(ATTRS)[:success]
  end

  # A field the resolved record simply does not carry is unverifiable, not a
  # divergence — blank must never read as "different".
  def test_register_proceeds_when_resolved_record_omits_a_field
    seed_agg(available: false)
    seed_voa
    seed_identity(sex: "", dob: "", name: "")
    seed_lock
    seed_existence
    seed_filer

    assert Reg.register(ATTRS)[:success]
  end

  # ==========================================================================
  # Tri-state lock — a lock that got NO broker response is unreachable
  # infrastructure, not contention. Collapsing the two reports an outage as a
  # busy record. Salvaged from #187 (M4).
  # ==========================================================================

  def test_register_returns_nil_when_lock_gets_no_response
    seed_agg(available: false)
    seed_voa
    seed_identity
    # The lock RPC is deliberately NOT seeded -> no broker response.

    assert_nil Reg.register(ATTRS), "no broker response must not be reported as contention"
    assert_empty filer_calls
  end

  def test_register_reports_lock_failed_on_actual_contention
    seed_agg(available: false)
    seed_voa
    seed_identity
    seed_lock(ok: false) # DDROK "0" — a real, answered refusal

    result = Reg.register(ATTRS)

    refute result[:success]
    assert_equal :lock_failed, result[:error]
    assert_empty filer_calls
  end
end
