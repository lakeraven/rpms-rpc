# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/version"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/problem"
require "rpms_rpc/api/pov"
require "rpms_rpc/api/health_factor"
require "rpms_rpc/api/exam_component"
require "rpms_rpc/api/measurement"
require "rpms_rpc/api/immunization_refusal"
require "rpms_rpc/api/referral"

# Regression tests for issue #217: the BGO write APIs were bound to
# wrong-semantics RPCs (a read, the refusal writer, the reproductive-history
# writer, and the V UPDATE/REVIEWED writer). Each test pins the API to the
# correct BGO* SET RPC with the INP layout the routine actually parses
# (routine:line cited per piece block).
class BgoWriteRebindTest < Minitest::Test
  DFN       = "8791"
  VISIT_IEN = "2090059"

  # Scripted broker: canned response per RPC name, records every call.
  class ScriptedClient
    attr_reader :calls

    def initialize(responses = {})
      @responses = responses
      @calls = []
    end

    def supports?(*) = true

    def call_rpc(rpc_name, *params)
      @calls << { rpc: rpc_name, params: params }
      @responses.fetch(rpc_name, "")
    end
  end

  def teardown
    RpmsRpc.reset!
  end

  def script(responses)
    RpmsRpc.reset!
    client = ScriptedClient.new(responses)
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  # -- Problem.add/update/delete → BGOPROB SET / BGOPROB DEL (finding 1) ----
  # SET^BGOPROB formals after RET: DFN, PRIEN, VIEN, ARRAY, SPEC, PIP
  # (BGOPROB.m:225). ARRAY "P" line layout (BGOPROB.m:218-220), parsed in
  # PROB^BGOPROB: SNOMED CT [2] (:246), Descriptive CT [3] (:260), Provider
  # text [4] (:241), Mapped ICD [5] (:240), Location [6] (:243), Onset [7]
  # (:244), Status [8] (:262), Class [9] (:245), Problem # [10] (:269),
  # Priority [11] (:271). Returns the problem IEN (BGOPROB.m:322).

  def test_problem_add_dispatches_bgoprob_set_not_the_edprob_read
    client = script("BGOPROB SET" => "6001")

    result = RpmsRpc::Problem.add(DFN, {
      icd_code: "I10", description: "Hypertension", location_ien: "3049",
      status: "Episodic"
    })

    call = client.calls.find { |c| c[:rpc] == "BGOPROB SET" }
    refute_nil call, "Problem.add must call BGOPROB SET (SET^BGOPROB — BGOPROB.m:225), " \
                     "not BGOPROB1 EDPROB, which is a READ (EDPROB^BGOPROB1 'Get active problems')"
    assert_equal DFN, call[:params][0], "formal 1 is DFN (BGOPROB.m:225)"
    assert_equal "", call[:params][1], "formal 2 PRIEN is empty for a new problem"
    assert result[:success]
    assert_equal 6001, result[:ien]
  end

  def test_problem_add_p_line_matches_bgoprob_layout
    client = script("BGOPROB SET" => "6001")

    RpmsRpc::Problem.add(DFN, {
      snomed_ct: "38341003", descriptive_ct: "1234567890", description: "Hypertension",
      icd_code: "I10", location_ien: "3049", onset_date: "3250101",
      status: "Chronic", problem_class: "", problem_number: "", priority: ""
    })

    array_param = client.calls.last[:params][3]
    assert_kind_of Array, array_param, "formal 4 ARRAY is a list param (BGOPROB.m:225,232)"
    assert_equal "P^38341003^1234567890^Hypertension^I10^3049^3250101^Chronic^^^",
      array_param.first
  end

  def test_problem_add_error_reply_is_failure
    # ERR^BGOUTL(1049) — no location (BGOPROB.m:276, BGOUTL.m:408-409)
    script("BGOPROB SET" => "-1049^Location must be specified")

    result = RpmsRpc::Problem.add(DFN, { icd_code: "I10", description: "HTN" })
    refute result[:success]
    assert_nil result[:ien]
    assert_equal "-1049^Location must be specified", result[:raw]
  end

  def test_problem_update_sends_problem_ien
    client = script("BGOPROB SET" => "5001")

    result = RpmsRpc::Problem.update(DFN, "5001", { icd_code: "I10", description: "HTN" })
    assert_equal "5001", client.calls.last[:params][1],
      "formal 2 PRIEN carries the problem IEN on edit (BGOPROB.m:225,290-291)"
    assert result[:success]
  end

  def test_problem_delete_dispatches_bgoprob_del_with_reason_piece_3
    client = script("BGOPROB DEL" => "")

    RpmsRpc::Problem.delete(DFN, "5001", reason: "Entered in error")

    call = client.calls.find { |c| c[:rpc] == "BGOPROB DEL" }
    refute_nil call, "Problem.delete must call BGOPROB DEL (DEL^BGOPROB — BGOPROB.m:210)"
    # PRIEN = Problem IEN ^ TYPE ^ DELETE REASON ^ COMMENT ^ PROB ID
    # (BGOPROB.m:209; REASON=$P(PRIEN,U,3) in DEL^BGOPROB3)
    assert_equal "5001^^Entered in error", call[:params][0]
  end

  # -- Pov.add → BGOVPOV SET (finding 4a) -----------------------------------
  # SET^BGOVPOV formals after RET: INP, QUAL, INJ, NORM, SPEC (BGOVPOV.m:291).
  # INP layout (BGOVPOV.m:285-286): VPOV IEN[1]^Visit IEN[2]^Problem IEN[3]^
  # Patient IEN[4]^Prov Text[5]^Descriptive CT[6]^SNOMED CT[7]^ICD code[8]^
  # Primary/Secondary[9]^Provider IEN[10]^asthma[11]^norm/abn[12]^
  # laterality[13]^fracture[14]; parsed at :298 (VIEN), :301 (VFIEN),
  # :302 (PRIEN), :303 (DFN).

  def test_pov_add_dispatches_bgovpov_set_with_inp_layout
    client = script("BGOVPOV SET" => "9001")

    result = RpmsRpc::Pov.add(DFN, VISIT_IEN, "I10",
      narrative: "Essential hypertension", modifiers: { primary: true })

    call = client.calls.find { |c| c[:rpc] == "BGOVPOV SET" }
    refute_nil call, "Pov.add must call BGOVPOV SET (SET^BGOVPOV — BGOVPOV.m:291), " \
                     "not BGOVUPD SET, which writes V UPDATE/REVIEWED (#9000010.54)"
    inp = call[:params][0].split("^", -1)
    assert_equal "", inp[0], "VPOV IEN empty for a new entry (BGOVPOV.m:301)"
    assert_equal VISIT_IEN, inp[1], "Visit IEN is INP piece 2 (BGOVPOV.m:298)"
    assert_equal DFN, inp[3], "Patient IEN is INP piece 4 (BGOVPOV.m:303)"
    assert_equal "Essential hypertension", inp[4], "Prov Text is INP piece 5 (BGOVPOV.m:285)"
    assert_equal "I10", inp[7], "ICD code is INP piece 8 (BGOVPOV.m:286)"
    assert_equal "P", inp[8], "Primary marker is INP piece 9 (BGOVPOV.m:286)"
    assert result[:success]
    assert_equal 9001, result[:ien]
  end

  def test_pov_add_injury_cause_rides_the_inj_formal
    client = script("BGOVPOV SET" => "9001")

    RpmsRpc::Pov.add(DFN, VISIT_IEN, "S93.4", narrative: "Ankle sprain",
      modifiers: { injury_cause: "W01.0" })

    call = client.calls.last
    assert_equal "W01.0", call[:params][2].split("^", -1)[0],
      "Cause DX is INJ piece 1, a separate formal (BGOVPOV.m:288,291)"
  end

  def test_pov_add_error_reply_is_failure
    # CHKVISIT^BGOUTL: ERR(1002) no visit / ERR(1003) bad visit (BGOUTL.m:283-284)
    script("BGOVPOV SET" => "-1003^Visit entry does not exist")

    result = RpmsRpc::Pov.add(DFN, VISIT_IEN, "I10", narrative: "HTN")
    refute result[:success]
    assert_nil result[:ien]
  end

  # -- HealthFactor.add → BGOVHF SET (finding 4b) ---------------------------
  # SET^BGOVHF INP (BGOVHF.m:44): HF Type IEN[1]^V File IEN[2]^Visit IEN[3]^
  # Severity[4]^Provider IEN[5]^Quantity[6]^Comment[7]^Event dt[8]; parsed at
  # :48-56,:68. Returns the V HEALTH FACTOR IEN (:83).

  def test_health_factor_add_dispatches_bgovhf_set_with_inp_layout
    client = script("BGOVHF SET" => "4001")

    result = RpmsRpc::HealthFactor.add(DFN, VISIT_IEN, "77", level: "HEAVY",
      narrative: "1 ppd")

    call = client.calls.find { |c| c[:rpc] == "BGOVHF SET" }
    refute_nil call, "HealthFactor.add must call BGOVHF SET (SET^BGOVHF — BGOVHF.m:45)"
    inp = call[:params][0].split("^", -1)
    assert_equal "77", inp[0], "HF Type IEN is INP piece 1 (BGOVHF.m:48)"
    assert_equal "", inp[1], "V File IEN empty for a new entry (BGOVHF.m:50)"
    assert_equal VISIT_IEN, inp[2], "Visit IEN is INP piece 3 (BGOVHF.m:52)"
    assert_equal "HEAVY", inp[3], "Severity is INP piece 4 (BGOVHF.m:53)"
    assert_equal "1 ppd", inp[6], "Comment is INP piece 7 (BGOVHF.m:56)"
    assert result[:success]
    assert_equal 4001, result[:ien]
  end

  # -- ExamComponent.add → BGOVEXAM SET (finding 4c) ------------------------
  # SET^BGOVEXAM INP (BGOVEXAM.m:103-104): V Exam IEN[1]^Exam IEN[2]^
  # Visit IEN[3]^Provider IEN[4]^Result[5]^Comment[6]^Event Date[7]^
  # Location IEN[8]^Other Location[9]^Historical[10]^DFN[11]; parsed at
  # :109-129. Returns the V EXAM IEN (:156).

  def test_exam_component_add_dispatches_bgovexam_set_with_inp_layout
    client = script("BGOVEXAM SET" => "3001")

    result = RpmsRpc::ExamComponent.add(DFN, VISIT_IEN, "28", finding: "N",
      narrative: "no abnormalities")

    call = client.calls.find { |c| c[:rpc] == "BGOVEXAM SET" }
    refute_nil call, "ExamComponent.add must call BGOVEXAM SET (SET^BGOVEXAM — BGOVEXAM.m:106)"
    inp = call[:params][0].split("^", -1)
    assert_equal "", inp[0], "V Exam IEN empty for a new entry (BGOVEXAM.m:109)"
    assert_equal "28", inp[1], "Exam type IEN is INP piece 2 (BGOVEXAM.m:111)"
    assert_equal VISIT_IEN, inp[2], "Visit IEN is INP piece 3 (BGOVEXAM.m:112)"
    assert_equal "N", inp[4], "Result is INP piece 5 (BGOVEXAM.m:123)"
    assert_equal "no abnormalities", inp[5], "Comment is INP piece 6 (BGOVEXAM.m:125)"
    assert_equal DFN, inp[10], "DFN is INP piece 11 (BGOVEXAM.m:115)"
    assert result[:success]
    assert_equal 3001, result[:ien]
  end

  # -- Measurement.add → BGOVMSR SET (finding 4d) ---------------------------
  # SET^BGOVMSR INP (BGOVMSR.m:104): Visit IEN[1]^V File IEN[2]^Type[3]^
  # Value[4]^Date/Time[5]; parsed at :108-118. Type accepts the AUTTMSR
  # abbreviation (:115). Returns the V MEASUREMENT IEN (:139).

  def test_measurement_add_dispatches_bgovmsr_set_with_inp_layout
    client = script("BGOVMSR SET" => "2001")

    result = RpmsRpc::Measurement.add(DFN, VISIT_IEN, "WT", "82", units: "kg")

    call = client.calls.find { |c| c[:rpc] == "BGOVMSR SET" }
    refute_nil call, "Measurement.add must call BGOVMSR SET (SET^BGOVMSR — BGOVMSR.m:105)"
    inp = call[:params][0].split("^", -1)
    assert_equal VISIT_IEN, inp[0], "Visit IEN is INP piece 1 (BGOVMSR.m:108)"
    assert_equal "", inp[1], "V File IEN empty for a new entry (BGOVMSR.m:111)"
    assert_equal "WT", inp[2], "Type abbreviation is INP piece 3 (BGOVMSR.m:114-115)"
    assert_equal "82", inp[3], "Value is INP piece 4 (BGOVMSR.m:117)"
    assert result[:success]
    assert_equal 2001, result[:ien]
  end

  # -- ImmunizationRefusal.record → BGOREF SET (findings 2+3) ---------------
  # BGOREP SET writes REPRODUCTIVE history (^AUPNREP — BGOREP.m:62-87; errors
  # on male patients at :86). The refusal writer is SET^BGOREF (BGOREF.m:8),
  # INP (BGOREF.m:4-5): Refusal IEN[1]^Refusal Type[2]^Item IEN[3]^
  # Patient IEN[4]^Refusal Date[5]^Comment[6]^Provider IEN[7]^Reason[8];
  # files ^AUPNPREF via $$REFSET2^BGOUTL2 (BGOREF.m:29). Immunization
  # refusals pass type "IMMUNIZATION" and the vaccine IEN (BGOVIMM2.m:100).
  # REFSET2 returns "" on success (BGOUTL2.m:126-129), -CODE^text on error.

  def test_immunization_refusal_dispatches_bgoref_set_not_bgorep
    client = script("BGOREF SET" => "")

    result = RpmsRpc::ImmunizationRefusal.record(DFN, "17", reason_ien: "3",
      narrative: "parental refusal", refusal_date: "3260908", provider_duz: "42")

    call = client.calls.find { |c| c[:rpc] == "BGOREF SET" }
    refute_nil call, "ImmunizationRefusal.record must call BGOREF SET (SET^BGOREF — " \
                     "BGOREF.m:8), not BGOREP SET (reproductive history — BGOREP.m:77)"
    inp = call[:params][0].split("^", -1)
    assert_equal "", inp[0], "Refusal IEN empty for a new refusal (BGOREF.m:14)"
    assert_equal "IMMUNIZATION", inp[1], "Refusal Type is INP piece 2 (BGOREF.m:15; BGOVIMM2.m:100)"
    assert_equal "17", inp[2], "vaccine (item) IEN is INP piece 3 (BGOREF.m:16)"
    assert_equal DFN, inp[3], "Patient IEN is INP piece 4 (BGOREF.m:11)"
    assert_equal "3260908", inp[4], "Refusal Date is INP piece 5 (BGOREF.m:17)"
    assert_equal "parental refusal", inp[5], "Comment is INP piece 6 (BGOREF.m:18)"
    assert_equal "42", inp[6], "Provider IEN is INP piece 7 (BGOREF.m:19)"
    assert_equal "3", inp[7], "Reason (file 9999999.102 IEN) is INP piece 8 (BGOREF.m:20,26-27)"
    assert result[:success], "REFSET2 returns empty string on success (BGOUTL2.m:126-129)"
  end

  def test_immunization_refusal_error_reply_is_failure
    # ERR^BGOUTL(1001) — patient not found (BGOREF.m:13)
    script("BGOREF SET" => "-1001^Patient not found")

    result = RpmsRpc::ImmunizationRefusal.record(DFN, "17", reason_ien: "3")
    refute result[:success]
    assert_equal "-1001^Patient not found", result[:raw]
  end

  def test_immunization_refusal_nil_broker_response_is_failure_not_success
    RpmsRpc.reset!
    client = Object.new
    def client.supports?(*) = true
    def client.call_rpc(*) = nil
    RpmsRpc.configure { |cfg| cfg.client = client }

    result = RpmsRpc::ImmunizationRefusal.record(DFN, "17", reason_ien: "3")
    refute result[:success], "broker silence must not read as a filed refusal"
  end

  # -- Referral.create (finding 2) ------------------------------------------
  # BGOREF SET writes refusals, and the real referral writer (BMC ADD
  # REFERRAL = SETREFRL^BMCRPC2, 39 positional formals) is already exposed
  # as Referral.add. create must not fake success.

  def test_referral_create_is_not_implemented
    client = script({})

    result = RpmsRpc::Referral.create(DFN, { specialty: "CARDIOLOGY" })

    refute result[:success]
    assert_equal :not_implemented, result[:error]
    assert_empty client.calls, "create must not call any RPC — BGOREF SET files refusals"
  end
end
