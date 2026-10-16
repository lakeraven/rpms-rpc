# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/medication"

# ORWPS ACTIVE (ACTIVE^ORWPS, ORWPS.m:17-51) returns one ~TYPE^FIELDS header per
# medication, then instruction lines and t-prefixed comment/reason lines until the
# next ~. FIELDS is ^TMP("PS",$J,n,0) from OCL^PSOORRL (outpatient PSOORRL.m:21-25;
# unit dose PSJORRE.m:42; IV PSJORRE.m:70; non-VA PSOORRL.m:122-123).
#
# Instructions and comments are each an Array of logical lines. The first line
# of either channel, and any line starting with "\", begins a new logical line
# (the "\" is dropped); any other line continues the previous one, appended as
# sent (wrapped chunks carry their own leading space: ORWPS.m:66, :82, :109;
# PSOORRL.m:48). Each logical line is then stripped of surrounding whitespace.
class MedicationActiveTest < Minitest::Test
  DFN = "8791"

  # Outpatient node 0: PSOORRL.m:21 builds eight pieces (expiration $P(RX2,"^",6)
  # at 4, refills at 5, order number at 8); PSOORRL.m:25 appends ST as piece 9.
  # Every row type carries status at piece 9 of the ^TMP node (outpatient
  # PSOORRL.m:25, pending PSOORRL.m:43, unit dose PSJORRE.m:42, IV PSJORRE.m:70,
  # non-VA PSOORRL.m:123). ORWPS.m:31 uses piece 8 as the CPRS order number when
  # marking clinic-annotated drug names.
  OP_ACTIVE_FIELDS = "4401R;O^METFORMIN 500MG TAB^^3271231^3^^^120345^ACTIVE"

  # STA 12 → ST "DISCONTINUED" even when piece 4 (expiration) is still in the
  # future (ST0 only forces EXPIRED when STA<12 and expiration < DT — PSOORRL.m:23-24).
  OP_DISCONTINUED_FIELDS = "5502R;O^LISINOPRIL 10MG TAB^^3280101^2^^^120346^DISCONTINUED"

  # Pending outpatient PSOORRL.m:42-43: IFN_P;O piece 1, drug piece 2, pieces 3-7
  # empty, order IEN piece 8, PENDING piece 9.
  OP_PENDING_FIELDS = "99P;O^AMOXICILLIN 500MG TAB^^^^^^887^PENDING"

  # Unit dose ^TMP node (PSJORRE.m:42): stop $P(ND2,U,4) piece 4, STAT piece 9.
  UD_ACTIVE_FIELDS = "99100U;I^ACETAMINOPHEN 325MG TAB^^3270601^^650^MG^^ACTIVE^^^^^^^^0^3270101"

  # IV ^TMP node (PSJORRE.m:70): FON;I piece 1, DN piece 2, infusion rate piece 3,
  # STOP piece 4, DO piece 6, $P(ND0,U,21) piece 8, STAT piece 9.
  IV_ACTIVE_FIELDS = "77123V;I^D5W 1000ML^125 ml/hr^3271201^^1000^^654321^ACTIVE"

  # Non-VA TMPBLD (PSOORRL.m:122-123): order IEN and status in pieces 8-9 only.
  # Piece 4 may be filled from a stale NVSDT on the wire (ORWPS.m:44) but carries
  # no reliable date for consumers.
  NV_ACTIVE_FIELDS = "42N;O^ASPIRIN 81MG TAB^^3250101^^^^887^ACTIVE"

  NV_SECOND_ROW_FIELDS = "43N;O^IBUPROFEN 200MG TAB^^3280615^^^^888^ACTIVE"

  # Inpatient layout still has a status piece (PSJORRE.m:42 piece 9); an empty
  # piece 9 must not be invented as ACTIVE.
  UD_NO_STATUS_FIELDS = "77100U;I^NORMAL SALINE 1000ML NS^^3271201^^1000^ML^^^^^^^^^^^3270101"

  def teardown
    RpmsRpc.reset!
  end

  # ACTIVE(LST,DFN) (ORWPS.m:17): broker frame is DFN only — LST is the return array.
  def test_active_for_patient_dispatches_orwps_active_with_dfn_only
    RpmsRpc.mock!
    RpmsRpc::Medication.active_for_patient(DFN)
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORWPS ACTIVE" }
    refute_nil call, "ORWPS ACTIVE was not called"
    assert_equal [ DFN ], call[:params]
  end

  def test_active_for_patient_invalid_dfn_returns_empty_without_dispatch
    with_raising_client do
      assert_equal [], RpmsRpc::Medication.active_for_patient(nil)
      assert_equal [], RpmsRpc::Medication.active_for_patient("")
      assert_equal [], RpmsRpc::Medication.active_for_patient("   ")
      assert_equal [], RpmsRpc::Medication.active_for_patient(0)
      assert_equal [], RpmsRpc::Medication.active_for_patient(-1)
    end
  end

  def test_active_for_patient_empty_wire_returns_empty_array
    with_orwps_active_wire([])
    assert_equal [], RpmsRpc::Medication.active_for_patient(DFN)
  end

  def test_active_for_patient_parses_outpatient_active_status_and_expiration
    with_orwps_active_wire([
      "~OP^#{OP_ACTIVE_FIELDS}",
      " METFORMIN 500MG TAB  Qty: 30 for 30 days",
      "\\ Sig: TAKE 1 TABLET BY MOUTH",
      " DAILY WITH BREAKFAST"
    ])
    rows = RpmsRpc::Medication.active_for_patient(DFN)
    assert_equal 1, rows.length
    row = rows.first

    assert_equal "4401R;O", row[:order_id]
    assert_equal "OP", row[:type]
    assert_equal "METFORMIN 500MG TAB", row[:name]
    assert_equal "ACTIVE", row[:status]
    assert_equal Date.new(2027, 12, 31), row[:stop_date]
    assert_equal [
      "METFORMIN 500MG TAB  Qty: 30 for 30 days",
      "Sig: TAKE 1 TABLET BY MOUTH DAILY WITH BREAKFAST"
    ], row[:instructions]
    assert_equal [], row[:comments]
  end

  def test_active_for_patient_keeps_discontinued_when_expiration_is_still_future
    with_orwps_active_wire([ "~OP^#{OP_DISCONTINUED_FIELDS}" ])
    rows = RpmsRpc::Medication.active_for_patient(DFN)
    assert_equal 1, rows.length
    row = rows.first

    assert_equal "DISCONTINUED", row[:status]
    assert_equal Date.new(2028, 1, 1), row[:stop_date]
  end

  def test_active_for_patient_parses_pending_outpatient_status_on_piece_nine
    with_orwps_active_wire([ "~OP^#{OP_PENDING_FIELDS}" ])
    rows = RpmsRpc::Medication.active_for_patient(DFN)
    assert_equal 1, rows.length
    row = rows.first

    assert_equal "99P;O", row[:order_id]
    assert_equal "OP", row[:type]
    assert_equal "AMOXICILLIN 500MG TAB", row[:name]
    assert_equal "PENDING", row[:status]
    assert_nil row[:stop_date]
  end

  def test_active_for_patient_parses_unit_dose_with_status_on_piece_nine
    with_orwps_active_wire([
      "~UD^#{UD_ACTIVE_FIELDS}",
      " ACETAMINOPHEN 325MG TAB",
      "\\Give: 650 MG"
    ])
    rows = RpmsRpc::Medication.active_for_patient(DFN)
    assert_equal 1, rows.length
    row = rows.first

    assert_equal "99100U;I", row[:order_id]
    assert_equal "UD", row[:type]
    assert_equal "ACETAMINOPHEN 325MG TAB", row[:name]
    assert_equal "ACTIVE", row[:status]
    assert_equal Date.new(2027, 6, 1), row[:stop_date]
    assert_equal [
      "ACETAMINOPHEN 325MG TAB",
      "Give: 650 MG"
    ], row[:instructions]
    assert_equal [], row[:comments]
  end

  def test_active_for_patient_parses_iv_row_with_status_stop_and_instructions
    with_orwps_active_wire([
      "~IV^#{IV_ACTIVE_FIELDS}",
      " D5W 1000ML",
      "\\125 ml/hr"
    ])
    rows = RpmsRpc::Medication.active_for_patient(DFN)
    assert_equal 1, rows.length
    row = rows.first

    assert_equal "77123V;I", row[:order_id]
    assert_equal "IV", row[:type]
    assert_equal "D5W 1000ML", row[:name]
    assert_equal "ACTIVE", row[:status]
    assert_equal Date.new(2027, 12, 1), row[:stop_date]
    assert_equal [
      "D5W 1000ML",
      "125 ml/hr"
    ], row[:instructions]
    assert_equal [], row[:comments]
  end

  def test_active_for_patient_parses_non_va_med_without_dates_on_wire
    with_orwps_active_wire([
      "~NV^#{NV_ACTIVE_FIELDS}",
      " ASPIRIN 81MG TAB",
      "\\ TAKE ONE TABLET BY MOUTH DAILY",
      "t\\ Patient takes OTC supply from home"
    ])
    rows = RpmsRpc::Medication.active_for_patient(DFN)
    assert_equal 1, rows.length
    row = rows.first

    assert_equal "42N;O", row[:order_id]
    assert_equal "NV", row[:type]
    assert_equal "ASPIRIN 81MG TAB", row[:name]
    assert_equal "ACTIVE", row[:status]
    assert_nil row[:stop_date]
    refute row.key?(:start_date)
    assert_equal [
      "ASPIRIN 81MG TAB",
      "TAKE ONE TABLET BY MOUTH DAILY"
    ], row[:instructions]
    assert_equal [
      "Patient takes OTC supply from home"
    ], row[:comments]
  end

  def test_active_for_patient_non_va_rows_carry_no_date_when_piece_four_is_stale
    with_orwps_active_wire([
      "~NV^#{NV_ACTIVE_FIELDS}",
      "~NV^#{NV_SECOND_ROW_FIELDS}"
    ])
    rows = RpmsRpc::Medication.active_for_patient(DFN)
    assert_equal 2, rows.length

    first, second = rows
    assert_nil first[:stop_date]
    refute first.key?(:start_date)
    assert_nil second[:stop_date]
    refute second.key?(:start_date)
    assert_equal "43N;O", second[:order_id]
    assert_equal "IBUPROFEN 200MG TAB", second[:name]
  end

  def test_active_for_patient_reassembles_wrapped_comment_fragments_into_one_line
    with_orwps_active_wire([
      "~UD^#{UD_ACTIVE_FIELDS}",
      "t\\ Patient reported mild nausea after the morning dose on",
      "t an empty stomach; will retry with food."
    ])
    rows = RpmsRpc::Medication.active_for_patient(DFN)
    assert_equal 1, rows.length
    row = rows.first

    assert_equal [
      "Patient reported mild nausea after the morning dose on an empty stomach; will retry with food."
    ], row[:comments]
  end

  def test_active_for_patient_nil_status_when_status_piece_absent
    with_orwps_active_wire([ "~UD^#{UD_NO_STATUS_FIELDS}" ])
    rows = RpmsRpc::Medication.active_for_patient(DFN)
    assert_equal 1, rows.length
    row = rows.first

    assert_nil row[:status]
    refute_equal "ACTIVE", row[:status]
  end

  def test_active_for_patient_one_record_per_header_instruction_lines_not_records
    with_orwps_active_wire([
      "~OP^#{OP_ACTIVE_FIELDS}",
      "\\ Sig: FIRST",
      "~OP^#{OP_DISCONTINUED_FIELDS}",
      "\\ Sig: SECOND"
    ])
    rows = RpmsRpc::Medication.active_for_patient(DFN)

    assert_equal 2, rows.length
    assert_equal [ "4401R;O", "5502R;O" ], rows.map { |r| r[:order_id] }
    refute rows.any? { |r| r[:order_id].to_s.start_with?("\\") }
  end

  def test_active_for_patient_ignores_lines_before_first_header
    with_orwps_active_wire([
      "broker noise or partial row",
      "~OP^#{OP_ACTIVE_FIELDS}"
    ])
    rows = RpmsRpc::Medication.active_for_patient(DFN)

    assert_equal 1, rows.length
    assert_equal "4401R;O", rows.first[:order_id]
  end

  # ORQQPS LIST path must stay on the condensed list RPC (#422 does not replace it).
  def test_medication_for_patient_still_dispatches_orqqps_list
    RpmsRpc.mock!
    RpmsRpc::Medication.for_patient(DFN)
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "ORQQPS LIST" }
    refute_nil call
    assert_equal [ DFN, "", "" ], call[:params]
  end

  private

  def with_orwps_active_wire(lines)
    client = RpmsRpc::MockClient.new
    wire = Array(lines)
    client.define_singleton_method(:call_rpc) do |rpc_name, *params|
      received_calls << { rpc: rpc_name, params: params, context: current_context }
      raise "unexpected RPC #{rpc_name}" unless rpc_name == "ORWPS ACTIVE"

      wire
    end
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def with_raising_client
    client = RpmsRpc::MockClient.new
    client.define_singleton_method(:call_rpc) do |rpc, *_params|
      raise "RPC dispatched for invalid identifier: #{rpc}"
    end
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = client }
    yield
  ensure
    RpmsRpc.reset!
  end
end
