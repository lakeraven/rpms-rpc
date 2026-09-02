# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/registration"

# Tests for RpmsRpc::Registration — the composed patient-registration flow:
#
#   VAFC VOA ADD PATIENT (ADD^VAFCPTAD → PATIENT #2 record, returns DFN)
#   → IDENTITY GUARD (ORWPT ID INFO on the resolved DFN; abort on mismatch)
#   → DDR LOCK/UNLOCK NODE on ^AUPNPAT(DFN)
#   → DDR GETS ENTRY DATA existence probe on file #9000001
#   → DDR FILER (UPDATE^DIE) filing the #9000001 stub (.01/.02/.11 DINUM'd to
#     the DFN — AUPNLK2.m:55-58), then the HRN into the 41 multiple and
#     tribe/community/classification/eligibility fields
#
# This replaces the retired "BHDPTRPC REGISTER" placeholder (no server
# implementation anywhere — docs/RPC_COVERAGE.md, "BHDPTRPC provenance").
#
# NB: there is deliberately NO HRN "D"-xref uniqueness pre-check. The old
# recreated pre-check was unimplementable — DDR LISTER with no FIELDS returns
# bare-IEN rows (no HRN piece, live: rpms-ydb-9.0 2026-09-02), and HRN
# uniqueness is not FileMan-enforced anyway (field .02's transform is
# format-only; its "D" xref is a plain SET index). Uniqueness is an
# AG-procedural invariant, unreachable via DDR — see RpmsRpc::Registration's
# KNOWN DIVERGENCES header.
#
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
  TODAY_FM = RpmsRpc::FilemanDateParser.format_date(Date.today)

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

  # Identity guard reads ORWPT ID INFO for the resolved DFN. Default seed
  # matches ATTRS so the guard passes; pass explicit pieces to force a mismatch.
  # Live shape: ssn^dob(fileman)^sex^race^^site^^name (stock_vista.rb:27-48).
  def seed_identity(dfn: 42, ssn: "900010001", dob: "2900102", sex: "F",
                    name: "DEMOPATIENT,UNA")
    @mock.seed(:patient_id_info, dfn.to_s,
      { ssn: ssn, dob: dob, sex: sex, name: name })
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

  def seed_happy_path
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
    # Pass 1 — #9000001 stub filed at the DINUM IEN = DFN (creation convention
    # AUPNLK2.m:55-57: DINUM=DFN, DLAYGO=9000001), the "+1," placeholder pinned
    # via DDRIENS (FILEC^DDR3: DDR3.m:12-13). AG's IHSPAT files .01 (name ptr)
    # PLUS .02 DATE ESTABLISHED = today and .11 ESTABLISHING USER = DUZ
    # (AUPNLK2.m:57). .11 is omitted here because the MockClient exposes no DUZ.
    # Values are FileMan-INTERNAL (UPDATE^DIE, no "E" flag — DDR3.m:15,18): .02
    # is the internal FileMan date.
    assert_equal [ "ADD",
                   { 1 => "9000001^.01^+1,^42", 2 => "9000001^.02^+1,^#{TODAY_FM}" },
                   "", { 1 => "42" } ], stub
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

  # ==========================================================================
  # Identity guard (BLOCKER-3) — VOA returns 1^DFN for a NEW patient AND for an
  # existing ICN, with no re-validation. Guard on the resolved DFN's identity.
  # ==========================================================================

  def test_register_aborts_on_identity_mismatch_before_any_write
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
    # No lock, no filing — the guard runs before the write path.
    assert_empty @mock.received_calls.select { |c| c[:rpc] == "DDR LOCK/UNLOCK NODE" }
    assert_empty filer_calls
  end

  def test_register_proceeds_when_identity_matches
    seed_happy_path # seed_identity matches ATTRS

    result = Reg.register(ATTRS)

    assert result[:success]
    assert_equal 42, result[:dfn]
  end

  def test_register_proceeds_when_identity_unverifiable
    # ORWPT ID INFO returns nothing (capability gap / no record): don't
    # false-reject — proceed (the freshly created record is the request's).
    seed_voa
    seed_lock
    seed_existence
    seed_filer

    result = Reg.register(ATTRS) # no seed_identity

    assert result[:success]
  end

  # ==========================================================================
  # Idempotent re-run (safe after partial failure)
  # ==========================================================================

  def test_register_rerun_with_existing_record_skips_stub_pass
    seed_voa # VOA returns the existing DFN for a known ICN (VAFCPTAD.m:55)
    seed_identity
    seed_lock
    seed_existence(exists: true)
    seed_filer(text: "[Data]\n+1,^5")

    result = Reg.register(ATTRS)

    assert result[:success]
    assert_equal 42, result[:dfn]
    refute result[:created]
    # No stub pass — only the completion pass against the existing IENS "42,".
    assert_equal 1, filer_calls.length
    refute_includes all_filer_rows, "9000001^.01^+1,^42"
    assert_includes all_filer_rows, "9000001^1108^42,^123"
    # The 41-multiple HRN row is DINUM'd to the facility IEN, so it is always
    # (re-)filed — UPDATE^DIE upserts it, no duplicate (no pre-check needed).
    assert_includes all_filer_rows, "9000001.41^.02^+1,42,^100001"
  end

  # M3: a real partial-failure retry. First register: stub filed OK, then the
  # COMPLETION pass fails — the two DDR FILER passes get DISTINCT replies via
  # the FIFO sequence seed. Re-register (idempotent): the record now exists, so
  # no stub pass, and the completion pass succeeds.
  def test_register_partial_failure_then_successful_retry
    seed_voa
    seed_identity
    seed_lock
    # First run: record absent → stub pass fires and succeeds, completion fails.
    @mock.seed(:ddr_gets_entry_data,
      Ddr.gets_entry_param(file: "9000001", iens: "42,", fields: ".01").to_s, "[ERROR]")
    @mock.seed_sequence(:ddr_filer, "ADD", [
      "[Data]\n+1,^42", # stub pass OK
      "[BEGIN_diERRORS]\n701^1^9000001^42,^1108^0\nThe value is not valid.\n[END_diERRORS]" # completion fails
    ])

    first = Reg.register(ATTRS)
    assert_equal :filer_rejected, first[:error]
    assert_equal 2, filer_calls.length, "stub pass + failing completion pass"

    # Retry: the #9000001 record now exists → existence probe returns data, so
    # NO stub pass; the completion pass now succeeds.
    @mock.seed(:ddr_gets_entry_data,
      Ddr.gets_entry_param(file: "9000001", iens: "42,", fields: ".01").to_s,
      "[Data]\n9000001^42^.01^42^DEMOPATIENT,UNA")
    @mock.seed_sequence(:ddr_filer, "ADD", [ "[Data]\n+1,^5" ])

    retry_result = Reg.register(ATTRS)
    assert retry_result[:success]
    refute retry_result[:created]
    # Exactly one NEW filer call on retry (the completion pass; no stub).
    assert_equal 3, filer_calls.length
  end

  def test_register_rerun_with_nothing_left_to_file_skips_filer
    attrs = ATTRS.reject { |k, _| %i[hrn location_ien tribe classification eligibility_status community].include?(k) }
    seed_voa(attrs)
    seed_identity
    seed_lock
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

  # M2: every VOA -1 is :voa_rejected. There is no fabricated :duplicate_identity
  # branch keyed off the error text — a real duplicate ICN is NOT a VOA error
  # (it returns 1^DFN and is handled by the identity guard).
  def test_register_voa_rejection_text_never_reclassified_as_duplicate
    seed_voa(reply: { status: -1, dfn_or_error: "Patient already exists" })

    result = Reg.register(ATTRS)

    assert_equal :voa_rejected, result[:error]
  end

  def test_register_lock_contention_stops_before_filing
    seed_voa
    seed_identity
    seed_lock(ok: false) # DDROK "0" — contention

    result = Reg.register(ATTRS)

    refute result[:success]
    assert_equal :lock_failed, result[:error]
    assert_empty filer_calls
    unlocks = @mock.received_calls.select do |c|
      c[:rpc] == "DDR LOCK/UNLOCK NODE" && c[:params].first == Ddr.unlock_param(node: LOCK_NODE)
    end
    assert_empty unlocks, "must not unlock a node it never locked"
  end

  # M4: a lock with NO broker response (nil) is unreachable-infrastructure, not
  # contention — register returns nil, distinct from the :lock_failed a "0"
  # gives. (The lock RPC is simply not seeded here → mock returns "".)
  def test_register_returns_nil_when_lock_gets_no_response
    seed_voa
    seed_identity

    assert_nil Reg.register(ATTRS)
  end

  def test_register_filer_rejection_surfaces_fileman_error_text
    seed_voa
    seed_identity
    seed_lock
    seed_existence
    seed_filer(text: "[BEGIN_diERRORS]\n701^1^9000001^+1,^.01^0\nThe value is not valid.\n[END_diERRORS]")

    result = Reg.register(ATTRS)

    refute result[:success]
    assert_equal :filer_rejected, result[:error]
    assert_match(/not valid/, result[:message])
  end

  def test_register_unlocks_even_when_filer_rejects
    seed_voa
    seed_identity
    seed_lock
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

  def test_register_without_hrn_files_no_41_rows
    attrs = ATTRS.reject { |k, _| %i[hrn location_ien].include?(k) }
    seed_voa(attrs)
    seed_identity
    seed_lock
    seed_existence
    seed_filer(text: "[Data]\n+1,^42")

    result = Reg.register(attrs)

    assert result[:success]
    # No pre-check RPC is ever issued (the pre-check was removed entirely).
    assert_nil @mock.received_calls.find { |c| c[:rpc] == "DDR LISTER" }
    assert all_filer_rows.none? { |r| r.start_with?("9000001.41^") }
  end
end
