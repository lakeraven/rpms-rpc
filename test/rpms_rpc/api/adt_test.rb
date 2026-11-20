# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc"
require "rpms_rpc/api/adt"
require_relative "../captured_replies"

# Tests for RpmsRpc::Adt's ORWPT reads over ^DGPM: admissions, current_location
# and discharge_datetime. Each replays a reply the build sent as PROVIDER,TEST
# on a throwaway container where DFN 4 was admitted (3261110.083022) and
# discharged (3261112.1, 10:00), and DFN 990013 admitted and still in, through
# stock $$ADD^BDGAPI (test/fixtures/captured_replies/adt-reads.yml). There is no
# stock movement-WRITE RPC; ADT writes for the reg/sched twin (lakeraven-ehr#412
# scenario #15) await a new FileMan-safe server RPC (openrpms#371), so only reads
# are wrapped here.
class AdtTest < Minitest::Test
  SLUG = "adt-reads"
  ADMITTED = Time.new(2026, 11, 10, 8, 30, 22)

  def teardown
    RpmsRpc.reset!
  end

  # A client that answers rpc with the named capture(s) of slug, and nothing else.
  def replay(rpc, *names, slug: SLUG)
    @client = CapturedReplies::ReplayCiaClient.new(rpc => names.map { |n| CapturedReplies.raw(slug, n) })
    RpmsRpc.configure { |cfg| cfg.client = @client }
  end

  def sent = @client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params] ] }

  # ---- admissions ----------------------------------------------------------

  def test_admissions_returns_each_admission_movement
    replay("ORWPT ADMITLST", "admitlst_one_stay")

    assert_equal [
      { movement_datetime: ADMITTED, location_ien: 16, location: "DEMO WARD", movement_type: "DIRECT",
        movement_ien: 1, tiu_document_ien: 0 }
    ], RpmsRpc::Adt.admissions(4)
    assert_equal [ [ "ORWPT ADMITLST", [ "4" ] ] ], sent
  end

  def test_admissions_is_empty_for_a_patient_never_admitted
    replay("ORWPT ADMITLST", "admitlst_no_stay")

    assert_equal [], RpmsRpc::Adt.admissions(990_012)
  end

  def test_admissions_returns_empty_for_invalid_dfn_and_sends_nothing
    replay("ORWPT ADMITLST")

    assert_equal [], RpmsRpc::Adt.admissions(nil)
    assert_equal [], RpmsRpc::Adt.admissions(0)
    assert_empty sent
  end

  # ---- current_location ----------------------------------------------------

  def test_current_location_returns_ward_when_admitted
    replay("ORWPT INPLOC", "inploc_admitted")

    assert_equal({ location_ien: 16, ward: "DEMO WARD", ward_synonym: "M" }, RpmsRpc::Adt.current_location(990_013))
    assert_equal [ [ "ORWPT INPLOC", [ "990013" ] ] ], sent
  end

  # INPLOC^ORWPT answers "0^^" for a patient who is not an inpatient, whether
  # discharged or never admitted.
  def test_current_location_nil_when_not_inpatient
    replay("ORWPT INPLOC", "inploc_discharged", "inploc_never_admitted")

    assert_nil RpmsRpc::Adt.current_location(4)
    assert_nil RpmsRpc::Adt.current_location(990_012)
  end

  def test_current_location_nil_for_invalid_dfn
    replay("ORWPT INPLOC")

    assert_nil RpmsRpc::Adt.current_location(nil)
    assert_empty sent
  end

  # Regression: INPLOC^ORWPT starts REC at 0 and only the HOSPITAL LOCATION
  # piece stays 0 when the ward has no 44-node link, so an ADMITTED patient on
  # an unlinked ward reads "0^DEMO WARD^M" (captured after that link was
  # cleared, adt-reads-unlinked-ward.yml). Testing only the leading piece read
  # those inpatients as "not admitted".
  def test_current_location_admitted_on_unlinked_ward_regression
    replay("ORWPT INPLOC", "inploc_admitted_unlinked_ward", slug: "adt-reads-unlinked-ward")

    loc = RpmsRpc::Adt.current_location(990_013)

    refute_nil loc, "0^name^synonym is an admitted patient on an unlinked ward"
    assert_equal({ location_ien: nil, ward: "DEMO WARD", ward_synonym: "M" }, loc)
  end

  # ---- discharge_datetime --------------------------------------------------

  # Regression: the routine returns +VAIP(17,1), and unary + drops trailing
  # zeros, so a 10:00 discharge arrives as "3261112.1". The odd-length time
  # part once parsed nil, reading a REAL discharge as no-data.
  def test_discharge_datetime_parses_the_plus_truncated_discharge
    replay("ORWPT DISCHARGE", "discharge_on_file")

    assert_equal Time.new(2026, 11, 12, 10, 0, 0), RpmsRpc::Adt.discharge_datetime(4, ADMITTED)
    assert_equal [ [ "ORWPT DISCHARGE", [ "4", "3261110.083022" ] ] ], sent
  end

  def test_discharge_datetime_nil_for_invalid_dfn
    replay("ORWPT DISCHARGE")

    assert_nil RpmsRpc::Adt.discharge_datetime(0, ADMITTED)
    assert_empty sent
  end

  # DISCHRG^ORWPT returns bare DT, today date-only, on every miss: an admission
  # not yet discharged, and a datetime that is no admission. It cannot say "not
  # found", so a date-only reply is the no-data sentinel and reads as nil, never
  # as a discharge at midnight today.
  def test_discharge_datetime_nil_on_date_only_dt_sentinel
    replay("ORWPT DISCHARGE", "discharge_still_in", "discharge_unknown_admission")

    assert_nil RpmsRpc::Adt.discharge_datetime(990_013, Time.new(2026, 11, 15, 9, 0, 0))
    assert_nil RpmsRpc::Adt.discharge_datetime(4, Time.new(2026, 11, 10, 8, 30, 0))
    assert_equal [ [ "ORWPT DISCHARGE", [ "990013", "3261115.0900" ] ],
                   [ "ORWPT DISCHARGE", [ "4", "3261110.0830" ] ] ], sent
  end

  # Regression: DateTime < Date in Ruby, so a `when Date` branch listed before
  # `when Time` formatted DateTime admit datetimes date-only, and DISCHRG^ORWPT
  # then cannot find the admission (it keys on the exact movement datetime,
  # stored to the second).
  def test_discharge_datetime_formats_a_datetime_admit_to_the_second_regression
    replay("ORWPT DISCHARGE", "discharge_on_file")

    assert_equal Time.new(2026, 11, 12, 10, 0, 0),
                 RpmsRpc::Adt.discharge_datetime(4, DateTime.new(2026, 11, 10, 8, 30, 22))
    assert_equal [ [ "ORWPT DISCHARGE", [ "4", "3261110.083022" ] ] ], sent
  end
end
