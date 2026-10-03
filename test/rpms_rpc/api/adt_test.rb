# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc/mappings"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/adt"

# Tests for RpmsRpc::Adt — the ADT/patient-movement read surface (ORWPT over
# ^DGPM). The broker is mocked. There is no stock movement-WRITE RPC; ADT writes
# for the reg/sched twin (lakeraven-ehr#412 scenario #15) await a FileMan-safe
# server RPC (rpms-ops#371), so only reads are wrapped here. The write contract
# is specified at the end of this file as skipped tests (#281).
class AdtTest < Minitest::Test
  ADMIT_T = Time.new(2026, 7, 1, 14, 30, 0)
  ADMIT_FM = RpmsRpc::FilemanDateParser.format_datetime(ADMIT_T)

  def setup
    RpmsRpc.mock!
  end

  def teardown
    RpmsRpc.reset!
  end

  # ---- admissions ----------------------------------------------------------

  def test_admissions_returns_movements
    RpmsRpc.client.seed_collection(:patient_admissions, [
      { movement_datetime: ADMIT_T, location_ien: 44, location: "3 WEST",
        movement_type: "ADMISSION", movement_ien: 900, tiu_document_ien: 0 }
    ])

    moves = RpmsRpc::Adt.admissions(100)

    assert_equal 1, moves.size
    assert_equal 44, moves.first[:location_ien]
    assert_equal "ADMISSION", moves.first[:movement_type]
    assert_equal "ORWPT ADMITLST", RpmsRpc.client.received_calls.last[:rpc]
    assert_equal [ "100" ], RpmsRpc.client.received_calls.last[:params]
  end

  def test_admissions_returns_empty_for_invalid_dfn
    assert_equal [], RpmsRpc::Adt.admissions(nil)
    assert_equal [], RpmsRpc::Adt.admissions(0)
  end

  # ---- current_location ----------------------------------------------------

  def test_current_location_returns_ward_when_admitted
    RpmsRpc.client.seed(:patient_current_location, "100",
                        { location_ien: 44, ward: "3 WEST", ward_synonym: "3W" })

    loc = RpmsRpc::Adt.current_location(100)

    refute_nil loc
    assert_equal 44, loc[:location_ien]
    assert_equal "3 WEST", loc[:ward]
  end

  def test_current_location_nil_when_not_inpatient
    # ORWPT INPLOC returns a leading 0 when the patient is not admitted.
    RpmsRpc.client.seed(:patient_current_location, "100",
                        { location_ien: 0, ward: "", ward_synonym: "" })

    assert_nil RpmsRpc::Adt.current_location(100)
  end

  def test_current_location_nil_for_invalid_dfn
    assert_nil RpmsRpc::Adt.current_location(nil)
  end

  # Regression: INPLOC^ORWPT emits "0^MED WARD^MW" for an ADMITTED patient
  # whose ward has no 44-node HOSPITAL LOCATION link (ORWPT.m:222-227 — REC
  # starts at 0 and only the linked-location piece stays 0; pieces 2-3 still
  # carry the ward). Testing only the leading piece read those inpatients as
  # "not admitted". Not-admitted is "0^^" (pieces 2-3 empty).
  def test_current_location_admitted_on_unlinked_ward_regression
    RpmsRpc.client.seed(:patient_current_location, "100",
                        { location_ien: 0, ward: "MED WARD", ward_synonym: "MW" })

    loc = RpmsRpc::Adt.current_location(100)

    refute_nil loc, "0^name^synonym is an admitted patient on an unlinked ward"
    assert_nil loc[:location_ien], "no 44-node link -> no hospital-location IEN"
    assert_equal "MED WARD", loc[:ward]
    assert_equal "MW", loc[:ward_synonym]
  end

  # ---- discharge_datetime --------------------------------------------------

  def test_discharge_datetime_parses_fileman
    discharge = Time.new(2026, 7, 5, 11, 0, 0)
    RpmsRpc.client.seed_scalar(:patient_discharge, "100",
                               RpmsRpc::FilemanDateParser.format_datetime(discharge))

    result = RpmsRpc::Adt.discharge_datetime(100, ADMIT_T)

    assert_equal 2026, result.year
    assert_equal 7, result.month
    assert_equal 5, result.day
    call = RpmsRpc.client.received_calls.last
    assert_equal "ORWPT DISCHARGE", call[:rpc]
    assert_equal [ "100", ADMIT_FM ], call[:params]
  end

  def test_discharge_datetime_nil_for_invalid_dfn
    assert_nil RpmsRpc::Adt.discharge_datetime(0, ADMIT_T)
  end

  # Regression pin: DISCHRG^ORWPT returns bare DT — TODAY, date-only — on
  # every miss (unknown admission: ORWPT.m:205; admission without a
  # discharge: ORWPT.m:207). It cannot say "not found", so a date-only reply
  # is the routine's no-data sentinel and must read as nil, never as a
  # discharge at midnight today.
  def test_discharge_datetime_nil_on_date_only_dt_sentinel
    RpmsRpc.client.seed_scalar(:patient_discharge, "100", "3260906")

    assert_nil RpmsRpc::Adt.discharge_datetime(100, ADMIT_T)
  end

  # Regression: the routine returns +VAIP(17,1), and unary + drops trailing
  # zeros — 10:00 arrives as "3260705.1" (ORWPT.m:208-209). The odd-length
  # time part parsed nil, reading a REAL discharge as no-data.
  def test_discharge_datetime_parses_plus_truncated_time_regression
    RpmsRpc.client.seed_scalar(:patient_discharge, "100", "3260705.1")

    result = RpmsRpc::Adt.discharge_datetime(100, ADMIT_T)

    refute_nil result, "\"3260705.1\" is 2026-07-05 10:00, not a miss"
    assert_equal Time.new(2026, 7, 5, 10, 0, 0), result
  end

  # Regression: DateTime < Date in Ruby, so a `when Date` branch listed before
  # `when Time` formatted DateTime admit datetimes date-only — DISCHRG^ORWPT
  # then can't find the admission (it keys on the exact movement datetime).
  def test_discharge_datetime_formats_datetime_admit_with_time_regression
    RpmsRpc::Adt.discharge_datetime(100, DateTime.new(2026, 7, 1, 14, 30, 0))

    call = RpmsRpc.client.received_calls.last
    assert_equal [ "100", ADMIT_FM ], call[:params],
                 "DateTime admit must format as FileMan date.time, not date-only"
  end

  # A movement datetime stored to the second (^DGPM stores HHMMSS) must
  # round-trip through Time without truncating the seconds.
  def test_discharge_datetime_preserves_seconds_in_admit_param
    RpmsRpc::Adt.discharge_datetime(100, Time.new(2026, 7, 1, 14, 30, 22))

    assert_equal [ "100", "3260701.143022" ],
                 RpmsRpc.client.received_calls.last[:params]
  end

  # ===========================================================================
  # MOVEMENT WRITES — the contract, specified before any server RPC exists (#281)
  # ===========================================================================
  #
  # Every test below is skipped: the skip reason is the open question. Nothing
  # here exists in lib/ (ADR 0008 — nothing in the gem without RPMS behind it),
  # and no RPC is named: the RPC that ends up serving these writes names itself
  # in the PR that wraps it, and these tests then lose their skips. The mock
  # seeds use placeholder mapping names (:adt_admit, ...) for that PR to define.
  #
  # Stock surfaces checked first, and why none of them serves the write:
  #
  # 1. The #8994 registry. The pinned bcer-9.0 registry
  #    (data/rpc_coverage/registry/bcer-9.0-20260913-1a2244c-ydb.txt; its
  #    source dump in rpms-ops @ f6033a2 carries each entry's routine) has
  #    movement READS only: ORWPT ADMITLST, ORWPT16 ADMITLST, ORWPT INPLOC,
  #    ORWPT DISCHARGE, ORWU INPLOC, BEHOENCX ADMITLST, BEHOENCX ADMITCUR,
  #    BEHOENCX INPLOC, BEHOPTCX INPLOC. No registered RPC runs a DGPM* or
  #    BDGAPI* routine.
  # 2. IHS's own movement API, ADD^BDGAPI / EDIT^BDGAPI / CANCEL^BDGAPI
  #    (PIMS 5.3, "IHS Changes To ADT": "silent API to add patient movement
  #    entries to file 405"). It is an M-level PEP taking a BDGR array (PAT,
  #    TRAN 1=admit 2=ward transfer 3=discharge 6=service transfer, DATE, USER,
  #    WARD, SRV, ATMD, UBAS, DSCT, ...). It does the FileMan-safe filing a
  #    write needs, but it is not broker-callable: this gem only calls
  #    registered RPCs, and none runs it. A thin registered RPC over it is one
  #    answer rpms-ops#371 can choose.
  # 3. BPRM. BPRM reaches the database through BMW SQL classes on the IRIS
  #    SuperServer port, not through XWB/BMX/CIA, so its write path is not
  #    reachable from this gem either.
  #
  # The parameters below follow BDGAPI's vocabulary, so a wrapper over it could
  # serve them without translation. The return shape follows Scheduling's
  # writes: { success: true, ... } on success, { success: false, error: <the
  # server's message> } on refusal. An invalid DFN is refused before the wire.

  MOVEMENT_WRITE_GAP = "no stock movement-write RPC: rpms-ops#371"
  TRANSFER_T = Time.new(2026, 7, 3, 9, 15, 0)
  DISCHARGE_T = Time.new(2026, 7, 5, 11, 0, 0)

  def admit_args
    { at: ADMIT_T, ward: "3 WEST", treating_specialty: "01", attending: 12,
      admit_source: "1", admitting_diagnosis: "CHEST PAIN" }
  end

  # ---- admit ---------------------------------------------------------------

  def test_admit_files_an_admission_and_returns_the_movement_ien
    skip MOVEMENT_WRITE_GAP
    RpmsRpc.client.seed(:adt_admit, "100", { error: "", movement_ien: 900 })

    result = RpmsRpc::Adt.admit(100, **admit_args)

    assert_equal({ success: true, movement_ien: 900 }, result)
    params = RpmsRpc.client.received_calls.last[:params]
    assert_equal "100", params[0]
    assert_includes params, ADMIT_FM, "the admission datetime goes to the server in FileMan form"
    assert_includes params, "3 WEST"
  end

  def test_admit_refuses_an_invalid_dfn_before_the_wire
    skip MOVEMENT_WRITE_GAP

    result = RpmsRpc::Adt.admit(0, **admit_args)

    refute result[:success]
    assert_match(/DFN/i, result[:error])
    assert_empty RpmsRpc.client.received_calls, "an invalid DFN must not reach the broker"
  end

  def test_admit_to_an_unknown_ward_returns_the_servers_refusal
    skip MOVEMENT_WRITE_GAP
    # BDGAPI's WARD check refuses with 2^"Ward error: <ward>" and files nothing.
    RpmsRpc.client.seed(:adt_admit, "100", { error: "Ward error: NO SUCH WARD" })

    result = RpmsRpc::Adt.admit(100, **admit_args, ward: "NO SUCH WARD")

    refute result[:success]
    assert_match(/Ward error: NO SUCH WARD/, result[:error])
    assert_nil result[:movement_ien]
  end

  # ---- transfer ------------------------------------------------------------

  def test_transfer_files_a_ward_transfer_and_returns_the_movement_ien
    skip MOVEMENT_WRITE_GAP
    RpmsRpc.client.seed(:adt_transfer, "100", { error: "", movement_ien: 901 })

    result = RpmsRpc::Adt.transfer(100, at: TRANSFER_T, ward: "4 EAST", room: "401-A")

    assert_equal({ success: true, movement_ien: 901 }, result)
    params = RpmsRpc.client.received_calls.last[:params]
    assert_equal "100", params[0]
    assert_includes params, RpmsRpc::FilemanDateParser.format_datetime(TRANSFER_T)
    assert_includes params, "4 EAST"
  end

  def test_transfer_refuses_an_invalid_dfn_before_the_wire
    skip MOVEMENT_WRITE_GAP

    result = RpmsRpc::Adt.transfer(nil, at: TRANSFER_T, ward: "4 EAST")

    refute result[:success]
    assert_match(/DFN/i, result[:error])
    assert_empty RpmsRpc.client.received_calls
  end

  def test_transfer_to_an_unknown_ward_returns_the_servers_refusal
    skip MOVEMENT_WRITE_GAP
    RpmsRpc.client.seed(:adt_transfer, "100", { error: "Ward error: NO SUCH WARD" })

    result = RpmsRpc::Adt.transfer(100, at: TRANSFER_T, ward: "NO SUCH WARD")

    refute result[:success]
    assert_match(/Ward error: NO SUCH WARD/, result[:error])
  end

  # ---- discharge -----------------------------------------------------------

  def test_discharge_files_a_discharge_and_returns_the_movement_ien
    skip MOVEMENT_WRITE_GAP
    # discharge_type: the TYPE OF MOVEMENT entry (#405.1) — BDGAPI's DSCT.
    RpmsRpc.client.seed(:adt_discharge, "100", { error: "", movement_ien: 902 })

    result = RpmsRpc::Adt.discharge(100, at: DISCHARGE_T, discharge_type: 16)

    assert_equal({ success: true, movement_ien: 902 }, result)
    params = RpmsRpc.client.received_calls.last[:params]
    assert_equal "100", params[0]
    assert_includes params, RpmsRpc::FilemanDateParser.format_datetime(DISCHARGE_T)
    assert_includes params, "16"
  end

  def test_discharge_refuses_an_invalid_dfn_before_the_wire
    skip MOVEMENT_WRITE_GAP

    result = RpmsRpc::Adt.discharge(-1, at: DISCHARGE_T, discharge_type: 16)

    refute result[:success]
    assert_match(/DFN/i, result[:error])
    assert_empty RpmsRpc.client.received_calls
  end

  def test_discharge_of_a_patient_not_admitted_returns_the_servers_refusal
    skip MOVEMENT_WRITE_GAP
    RpmsRpc.client.seed(:adt_discharge, "100", { error: "Patient is not currently admitted" })

    result = RpmsRpc::Adt.discharge(100, at: DISCHARGE_T, discharge_type: 16)

    refute result[:success]
    assert_match(/not currently admitted/, result[:error])
  end

  # ---- cancel_movement -----------------------------------------------------

  def test_cancel_movement_cancels_by_movement_ien
    skip MOVEMENT_WRITE_GAP
    # movement_ien: the #405 entry, as admissions() returns it.
    RpmsRpc.client.seed(:adt_cancel_movement, "100", { error: "" })

    result = RpmsRpc::Adt.cancel_movement(100, 900)

    assert_equal({ success: true }, result)
    assert_equal [ "100", "900" ], RpmsRpc.client.received_calls.last[:params]
  end

  def test_cancel_movement_refuses_an_invalid_dfn_before_the_wire
    skip MOVEMENT_WRITE_GAP

    result = RpmsRpc::Adt.cancel_movement(0, 900)

    refute result[:success]
    assert_match(/DFN/i, result[:error])
    assert_empty RpmsRpc.client.received_calls
  end

  def test_cancel_movement_of_an_unknown_movement_returns_the_servers_refusal
    skip MOVEMENT_WRITE_GAP
    RpmsRpc.client.seed(:adt_cancel_movement, "100", { error: "Movement not found" })

    result = RpmsRpc::Adt.cancel_movement(100, 999_999)

    refute result[:success]
    assert_match(/not found/, result[:error])
  end

  # ---- the tracker the write gap points at ---------------------------------

  # The ADT sources used to cite a closed ^XWB export defect (the number is
  # built below so this file does not contain it) instead of the server-side
  # movement-write tracker, rpms-ops#371. All three must point at the live one.
  def test_adt_sources_cite_the_movement_write_tracker
    root = File.expand_path("../../..", __dir__)
    stale = "rpms-ops##{366}"
    [ "lib/rpms_rpc/api/adt.rb", "test/rpms_rpc/api/adt_test.rb", "lib/rpms_rpc/mappings/stock_vista.rb" ].each do |path|
      src = File.read(File.join(root, path))
      assert_includes src, "rpms-ops#371", "#{path} must cite the movement-write tracker"
      refute_includes src, stale, "#{path} cites #{stale}, an unrelated closed issue"
    end
  end
end
