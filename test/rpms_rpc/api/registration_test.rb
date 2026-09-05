# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/registration"

# Tests for RpmsRpc::Registration — the composed patient-registration flow:
#
#   VAFC VOA ADD PATIENT (ADD^VAFCPTAD → PATIENT #2 record, returns DFN)
#   → DDR LOCK/UNLOCK NODE on ^AUPNPAT(DFN)
#   → DDR LISTER uniqueness pre-check on the HRN "D" cross-reference
#   → DDR GETS ENTRY DATA existence probe on file #9000001
#   → DDR FILER (UPDATE^DIE) filing #9000001 (.01 DINUM'd to the DFN),
#     the HRN into the 41 multiple, and tribe/community/classification/
#     eligibility fields
#
# This replaces a removed placeholder wire name (no server implementation
# anywhere — docs/RPC_COVERAGE.md provenance notes).
# All data below is synthetic (DEMOPATIENT names, 900-series pseudo-SSNs).
class RegistrationTest < Minitest::Test
  Reg = RpmsRpc::Registration
  Ddr = RpmsRpc::DdrFileman

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
  end

  def teardown
    RpmsRpc.reset!
  end

  # -- seeding helpers -------------------------------------------------------

  def seed_voa(attrs = ATTRS, reply: { status: 1, dfn_or_error: "42" })
    @mock.seed(:voa_add_patient, Reg.voa_param(attrs).to_s, reply)
  end

  def seed_lock(node: LOCK_NODE, ok: true)
    @mock.seed(:ddr_lock_unlock_node, Ddr.lock_param(node: node).to_s, ok)
  end

  def seed_hrn_listing(hrn: "100001", text: "[Data]")
    key = Ddr.lister_param(file: "9000001", max: "*", part: hrn, xref: "D").to_s
    @mock.seed(:ddr_lister, key, text)
  end

  def seed_existence(dfn: 42, exists: false)
    key = Ddr.gets_entry_param(file: "9000001", iens: "#{dfn},", fields: ".01").to_s
    text = exists ? "[Data]\n9000001^#{dfn}^.01^#{dfn}^DEMOPATIENT,UNA" : "[ERROR]"
    @mock.seed(:ddr_gets_entry_data, key, text)
  end

  def seed_filer(text: "[Data]\n+1,^42\n+2,^5")
    @mock.seed(:ddr_filer, "ADD", text)
  end

  def seed_happy_path
    seed_voa
    seed_lock
    seed_hrn_listing
    seed_existence
    seed_filer
  end

  def filer_calls
    @mock.received_calls.select { |c| c[:rpc] == "DDR FILER" }
  end

  def all_filer_rows
    filer_calls.flat_map { |c| c[:params][1].values }
  end

  # ==========================================================================
  # VOA param construction
  # ==========================================================================

  def test_voa_param_builds_named_list_in_vafcptad_order
    param = Reg.voa_param(ATTRS)

    # Required elements per ADD^VAFCPTAD (VAFCPTAD.m:10-19); values are
    # FileMan-external (each runs through CHK^DIE server-side).
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
    # "LAST^FIRST MIDDLE" reassembles server-side to the identical
    # "LAST,FIRST MIDDLE" (VAFCPTAD.m:59-63), so everything after the
    # comma rides in the FIRST piece.
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
    # SSN must be PRESENT but may be null → server files a pseudo-SSN
    # (VAFCPTAD.m:75-83)
    param = Reg.voa_param(ATTRS.merge(ssn: nil))

    assert_equal "", param["SSN"]
  end

  def test_voa_param_includes_optional_elements_when_given
    param = Reg.voa_param(ATTRS.merge(
      pob_city: "EXAMPLE CITY", pob_state: "MT", mothers_maiden_name: "DEMOMAIDEN,ONE"
    ))

    # Optional elements POBCTY/POBST/MMN (VAFCPTAD.m:21-24)
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
  # Composed register — happy path
  # ==========================================================================

  def test_register_success_returns_dfn_and_created
    seed_happy_path

    result = Reg.register(ATTRS)

    assert result[:success]
    assert_equal 42, result[:dfn]
    assert result[:created]
  end

  def test_register_files_stub_then_hrn_and_ihs_fields_in_two_filer_passes
    seed_happy_path

    Reg.register(ATTRS)

    stub, completion = filer_calls.map { |c| c[:params] }
    refute_nil completion, "expected two DDR FILER passes (stub + completion)"
    # Pass 1 — #9000001 .01 stub filed at the DINUM IEN = DFN (creation
    # convention: AUPNLK2.m:57 — DINUM=DFN, DLAYGO=9000001), the "+1,"
    # placeholder pinned via DDRIENS (FILEC^DDR3: DDR3.m:12-13). Values are
    # FileMan-INTERNAL: UPDATE^DIE runs with no "E" flag (DDR3.m:15,18).
    assert_equal [ "ADD", { 1 => "9000001^.01^+1,^42" }, "", { 1 => "42" } ], stub
    # Pass 2 — HRN rides the 41 multiple against the now-real "42," IENS:
    # .01 = facility (DINUM'd to the location IEN — AGACT.m:10 DA=DUZ(2)),
    # .02 = HEALTH RECORD NO. (AG1.m:53-54, AGEDNAME.m:63); then the IHS
    # completion fields (1108 tribe / 1111 classification / 1112
    # eligibility / 1118 community — citations in Registration).
    mode, root, flags, iens = completion
    assert_equal "ADD", mode
    assert_equal "", flags
    assert_equal "9000001.41^.01^+1,42,^5", root[1]
    assert_equal "9000001.41^.02^+1,42,^100001", root[2]
    assert_equal "9000001^1108^42,^123", root[3]
    assert_equal "9000001^1111^42,^13", root[4]
    assert_equal "9000001^1112^42,^I", root[5]
    assert_equal "9000001^1118^42,^EXAMPLE COMMUNITY", root[6]
    assert_equal({ 1 => "5" }, iens)
  end

  def test_register_locks_then_unlocks_aupnpat_node
    seed_happy_path

    Reg.register(ATTRS)

    lock_calls = @mock.received_calls.select { |c| c[:rpc] == "DDR LOCK/UNLOCK NODE" }
    assert_equal [ Ddr.lock_param(node: LOCK_NODE), Ddr.unlock_param(node: LOCK_NODE) ],
                 lock_calls.map { |c| c[:params].first }
  end

  def test_register_supports_extra_fields_escape_hatch
    seed_happy_path

    Reg.register(ATTRS.merge(extra_fields: [ { field: "1110", value: "4/4" } ]))

    assert_includes all_filer_rows, "9000001^1110^42,^4/4"
  end

  # ==========================================================================
  # Idempotent re-run (safe after partial failure)
  # ==========================================================================

  def test_register_rerun_with_existing_record_and_hrn_skips_add_rows
    seed_voa # VOA returns the existing DFN for a known ICN (VAFCPTAD.m:55)
    seed_lock
    seed_hrn_listing(text: "[Data]\n42^100001") # HRN already filed for this DFN
    seed_existence(exists: true)
    seed_filer(text: "[Data]")

    result = Reg.register(ATTRS)

    assert result[:success]
    assert_equal 42, result[:dfn]
    refute result[:created]
    # No stub pass, no 41-multiple rows — only field edits against the
    # existing IENS "42,".
    assert_equal 1, filer_calls.length
    refute_includes all_filer_rows, "9000001^.01^+1,^42"
    assert all_filer_rows.none? { |r| r.start_with?("9000001.41^") }
    assert_includes all_filer_rows, "9000001^1108^42,^123"
  end

  def test_register_rerun_with_existing_record_but_missing_hrn_adds_41_entry
    seed_voa
    seed_lock
    seed_hrn_listing(text: "[Data]")
    seed_existence(exists: true)
    seed_filer(text: "[Data]\n+2,^5")

    result = Reg.register(ATTRS)

    assert result[:success]
    assert_equal 1, filer_calls.length, "no stub pass for an existing record"
    root, iens = filer_calls.first[:params].values_at(1, 3)
    assert_includes root.values, "9000001.41^.01^+1,42,^5"
    assert_includes root.values, "9000001.41^.02^+1,42,^100001"
    assert_equal({ 1 => "5" }, iens)
  end

  def test_register_rerun_with_nothing_left_to_file_skips_filer
    attrs = ATTRS.reject { |k, _| %i[tribe classification eligibility_status community].include?(k) }
    seed_voa(attrs)
    seed_lock
    seed_hrn_listing(text: "[Data]\n42^100001")
    seed_existence(exists: true)

    result = Reg.register(attrs)

    assert result[:success]
    refute result[:created]
    assert_empty filer_calls, "no DDR FILER call expected when everything is already filed"
  end

  # ==========================================================================
  # Error taxonomy
  # ==========================================================================

  def test_register_voa_rejection_returns_error_with_message
    seed_voa(reply: { status: -1, dfn_or_error: "PREFERRED FACILITY is a required field." })

    result = Reg.register(ATTRS)

    refute result[:success]
    assert_equal :voa_rejected, result[:error]
    assert_match(/PREFERRED FACILITY/, result[:message])
    assert_empty @mock.received_calls.reject { |c| c[:rpc] == "VAFC VOA ADD PATIENT" },
                 "no DDR call may follow a VOA rejection"
  end

  def test_register_classifies_duplicate_identity
    seed_voa(reply: { status: -1, dfn_or_error: "Patient already exists" })

    result = Reg.register(ATTRS)

    assert_equal :duplicate_identity, result[:error]
  end

  def test_register_lock_failure_stops_before_filing
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

  def test_register_hrn_taken_by_other_patient
    seed_voa
    seed_lock
    seed_hrn_listing(text: "[Data]\n77^100001") # same HRN, different DFN

    result = Reg.register(ATTRS)

    refute result[:success]
    assert_equal :hrn_taken, result[:error]
    assert_empty filer_calls
  end

  def test_register_hrn_prefix_match_with_differing_value_is_not_taken
    seed_voa
    seed_lock
    # PART matching is prefix matching — "100001A" is not our HRN.
    seed_hrn_listing(text: "[Data]\n77^100001A")
    seed_existence
    seed_filer

    result = Reg.register(ATTRS)

    assert result[:success]
  end

  def test_register_filer_rejection_surfaces_fileman_error_text
    seed_voa
    seed_lock
    seed_hrn_listing
    seed_existence
    seed_filer(text: "[BEGIN_diERRORS]\n701^1^9000001^+1,^.01^0\nThe value is not valid.\n[END_diERRORS]")

    result = Reg.register(ATTRS)

    refute result[:success]
    assert_equal :filer_rejected, result[:error]
    assert_match(/not valid/, result[:message])
  end

  def test_register_unlocks_even_when_filer_rejects
    seed_voa
    seed_lock
    seed_hrn_listing
    seed_existence
    seed_filer(text: "[BEGIN_diERRORS]\n701^1^9000001^+1,^.01^0\nBad.\n[END_diERRORS]")

    Reg.register(ATTRS)

    unlock = @mock.received_calls.last
    assert_equal "DDR LOCK/UNLOCK NODE", unlock[:rpc]
    assert_equal Ddr.unlock_param(node: LOCK_NODE), unlock[:params].first
  end

  def test_register_returns_nil_when_broker_gives_no_response
    # Nothing seeded — the mock returns "" for the VOA call.
    assert_nil Reg.register(ATTRS)
  end

  def test_register_without_hrn_skips_lister_precheck
    attrs = ATTRS.reject { |k, _| %i[hrn location_ien].include?(k) }
    seed_voa(attrs)
    seed_lock
    seed_existence
    seed_filer(text: "[Data]\n+1,^42")

    result = Reg.register(attrs)

    assert result[:success]
    assert_nil @mock.received_calls.find { |c| c[:rpc] == "DDR LISTER" }
    assert all_filer_rows.none? { |r| r.start_with?("9000001.41^") }
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
