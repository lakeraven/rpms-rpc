# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc/version"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/reminders"

# RpmsRpc::Reminders reads what RPMS's own reminder evaluation returns:
# ORQQPXRM REMINDERS APPLICABLE -> APPL^ORQQPXRM (ORQQPXRM.m:10-11) ->
# EVALCOVR^ORQQPX (ORQQPX.m:232-236) -> AVAL^PXRMRPCA (PXRMRPCA.m:49-82).
# Rows below are written in that routine's reply layout (#238).
class RemindersTest < Minitest::Test
  PATIENT_DFN  = "8791"
  LOCATION_IEN = "11"

  # IEN^PRINT NAME^DUE DATE^LAST DONE^PRIORITY^DUE FLAG^DIALOG^^^^DIALOG WIPE
  # (PXRMRPCA.m:76 for applicable rows, :80 for not-applicable rows).
  AVAL_ROWS = [
    "1001^Diabetic Foot Exam^3261016^3251016^1^1^1^^^^0",
    "1002^Influenza Vaccine^DUE NOW^^2^1^0^^^^0",
    "1003^Mammogram^3270301^3260301^3^0^1^^^^1",
    "1004^Colonoscopy^^^^2^0^^^^0",
    "1005^Broken Logic^^^2^3^0^^^^0",
    "1006^No Frequency^CNBD^^2^4^0^^^^0"
  ].freeze

  def setup
    RpmsRpc.mock! do |m|
      m.seed_keyed_collection(:reminders_applicable, PATIENT_DFN,
                              AVAL_ROWS.map { |row| RpmsRpc::DataMapper[:reminders_applicable].parse_one(row) })
    end
  end

  def teardown
    RpmsRpc.reset!
  end

  def rows = RpmsRpc::Reminders.applicable(PATIENT_DFN, LOCATION_IEN)

  def test_dispatches_orqqpxrm_reminders_applicable_with_dfn_and_location
    rows
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORQQPXRM REMINDERS APPLICABLE" }

    refute_nil call
    assert_equal [ PATIENT_DFN, LOCATION_IEN ], call[:params]
  end

  def test_never_reads_the_triage_summary
    rows
    assert_nil RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BGOTRG GETSUM" }
  end

  def test_location_is_optional_and_sent_empty
    RpmsRpc::Reminders.applicable(PATIENT_DFN)
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORQQPXRM REMINDERS APPLICABLE" }

    assert_equal [ PATIENT_DFN, "" ], call[:params]
  end

  def test_row_carries_the_aval_fields
    first = rows.first

    assert_equal 1001, first[:id]
    assert_equal "Diabetic Foot Exam", first[:name]
    assert_equal :due, first[:status]
    assert_equal 1, first[:due_flag]
    assert_equal Date.new(2026, 10, 16), first[:due_date]
    assert_equal false, first[:due_now]
    assert_equal Date.new(2025, 10, 16), first[:last_done]
    assert_equal 1, first[:priority]
    assert_equal true, first[:has_dialog]
  end

  def test_due_flag_maps_to_the_aval_status_codes
    # PXRMRPCA.m:56-67: 2 is the default (not applicable), 0 applicable,
    # 1 due, 3 error, 4 cannot be determined.
    assert_equal %i[due due applicable not_applicable error cannot_be_determined],
                 rows.map { |r| r[:status] }
  end

  def test_due_now_sentinel_is_kept_and_not_read_as_a_date
    # PXRMDATE.m:132: no resolution date -> DUEDATE is the text "DUE NOW".
    influenza = rows.find { |r| r[:id] == 1002 }

    assert_equal true, influenza[:due_now]
    assert_nil influenza[:due_date]
    assert_nil influenza[:last_done]
  end

  def test_cnbd_due_date_sentinel_is_not_a_date
    # PXRMDATE.m:129: no frequency -> DUEDATE is the text "CNBD".
    cnbd = rows.find { |r| r[:id] == 1006 }

    assert_equal :cannot_be_determined, cnbd[:status]
    assert_nil cnbd[:due_date]
    assert_equal false, cnbd[:due_now]
  end

  def test_not_applicable_rows_are_returned_as_rpms_returns_them
    # PXRMRPCA.m:78-80: N/A rows carry no dates and no priority.
    colonoscopy = rows.find { |r| r[:id] == 1004 }

    assert_equal :not_applicable, colonoscopy[:status]
    assert_nil colonoscopy[:priority]
    assert_nil colonoscopy[:due_date]
    assert_equal false, colonoscopy[:has_dialog]
  end

  def test_unknown_due_flag_yields_nil_status
    RpmsRpc.mock! do |m|
      m.seed_keyed_collection(:reminders_applicable, PATIENT_DFN, [
        RpmsRpc::DataMapper[:reminders_applicable].parse_one("2001^Odd^^^2^9^0^^^^0")
      ])
    end

    assert_nil rows.first[:status]
  end

  def test_returns_empty_for_blank_or_non_positive_dfn_without_calling
    assert_equal [], RpmsRpc::Reminders.applicable(nil, LOCATION_IEN)
    assert_equal [], RpmsRpc::Reminders.applicable("", LOCATION_IEN)
    assert_equal [], RpmsRpc::Reminders.applicable("0", LOCATION_IEN)
    assert_empty RpmsRpc.client.received_calls
  end

  def test_returns_empty_when_nothing_evaluates
    RpmsRpc.mock!
    assert_equal [], rows
  end

  def test_visit_keyed_read_is_gone
    refute_respond_to RpmsRpc::Reminders, :for_visit,
                      "RPMS has no visit-keyed reminder method (ADR 0008 section 3)"
  end
end
