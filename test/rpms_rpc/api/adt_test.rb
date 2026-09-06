# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc/mappings"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/adt"

# Tests for RpmsRpc::Adt — the ADT/patient-movement read surface (ORWPT over
# ^DGPM). The broker is mocked. There is no stock movement-WRITE RPC; ADT writes
# for the reg/sched twin (lakeraven-ehr#412 scenario #15) await a new FileMan-
# safe server RPC (rpms-ops#366), so only reads are wrapped here.
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
end
