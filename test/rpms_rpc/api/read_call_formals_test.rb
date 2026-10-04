# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/version"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/patient"
require "rpms_rpc/api/problem"
require "rpms_rpc/api/medication"
require "rpms_rpc/api/health_summary"
require "rpms_rpc/api/note_template"
require "rpms_rpc/api/order"
require "rpms_rpc/api/symptom"
require "rpms_rpc/api/vital"

# Issue #259: each read call sends the formal list its routine declares.
#
# The formal lists are the routines' own label lines on a built 9.0 YottaDB
# image (the registry's formal_params column, cited per test). The first
# formal is the return variable the broker supplies; the gem's P1 fills the
# second, and so on. A frame that stops short leaves the next formal
# undefined and the call dies in M (%YDB-E-LVUNDEF) before it answers.
#
# These tests pin the FRAME: what MockClient received, not what it answered.
class ReadCallFormalsTest < Minitest::Test
  DFN = "8791"
  VSTR = "349;3260514.09;A;2090059"

  def setup
    RpmsRpc.mock!
  end

  def teardown
    RpmsRpc.reset!
  end

  def params_sent_to(rpc)
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == rpc }
    refute_nil call, "#{rpc} was not called"
    call[:params]
  end

  # LIST(ORY,ORPT,ORSTRTDT,ORSTOPDT)^ORQQPS (ORQQPS.m:4). OCL^PSOORRL
  # $G's both dates and defaults the start to 120 days back when it is
  # empty (PSOORRL.m:15).
  def test_medication_for_patient_sends_dfn_and_both_dates
    RpmsRpc::Medication.for_patient(DFN)
    assert_equal [ DFN, "", "" ], params_sent_to("ORQQPS LIST")
  end

  # LIST(ORPY,DFN,STATUS)^ORQQPL (ORQQPL.m:3-5): STATUS "" = all problems.
  def test_problem_for_patient_sends_dfn_and_status
    RpmsRpc::Problem.for_patient(DFN)
    assert_equal [ DFN, "" ], params_sent_to("ORQQPL LIST")
  end

  # DETAIL(Y,DFN,PROBIEN,ID)^ORQQPL (ORQQPL.m:21): the problem IEN is the
  # THIRD formal, so a problem detail needs the patient in front of it.
  def test_problem_details_sends_dfn_then_problem_ien
    RpmsRpc::Problem.details(DFN, "5001")
    assert_equal [ DFN, "5001" ], params_sent_to("ORQQPL DETAIL")
  end

  # RPT(ROOT,DFN,RPTID,HSTYPE,DTRANGE,EXAMID,ALPHA,OMEGA)^ORWRP (ORWRP.m:88).
  # The Health Summary report is ID 1 in file 101.24 (ORWRP REPORT LISTS
  # row "1^Health Summary^..."); HSTYPE is the summary type IEN.
  def test_health_summary_for_patient_sends_the_seven_report_formals
    RpmsRpc::HealthSummary.for_patient(DFN)
    assert_equal [ DFN, "1", "1", "", "", "", "" ], params_sent_to("ORWRP REPORT TEXT")
  end

  def test_health_summary_component_data_sends_the_seven_report_formals
    RpmsRpc::HealthSummary.component_data(DFN, :medications)
    assert_equal [ DFN, "1", "1", "", "", "", "" ], params_sent_to("ORWRP REPORT TEXT")
  end

  # GETTEXT(TIUY,DFN,VSTR,TIUX)^TIUSRVT (TIUSRVT.m:67) expands the
  # boilerplate TEXT it is handed: BLRPLT^TIUSRVD reads @ROOT@(n,0)
  # (TIUSRVD.m:82-83) with ROOT="TIUX", so each line goes over as TIUX(n,0).
  def test_note_template_text_sends_dfn_visit_and_text_as_n_0_nodes
    RpmsRpc::NoteTemplate.text([ "Patient |PATIENT NAME|", "Age |PATIENT AGE|" ], dfn: DFN, visit_string: VSTR)
    assert_equal [ DFN, VSTR, { [ 1, 0 ] => "Patient |PATIENT NAME|", [ 2, 0 ] => "Age |PATIENT AGE|" } ],
                 params_sent_to("TIU TEMPLATE GETTEXT")
  end

  # RESULT(REF,DFN,ORID,ID)^ORWOR (ORWOR.m:29-34): ORDERS^ORCXPND1 reads ID
  # as the file 100 IEN (ORCXPND1.m:91); DFN builds ORVP.
  def test_order_result_sends_dfn_then_order_ien_twice
    RpmsRpc::Order.result(DFN, "5001")
    assert_equal [ DFN, "5001", "5001" ], params_sent_to("ORWOR RESULT")
  end

  # SYMPTOMS(Y,FROM,DIR)^ORWDAL32 (ORWDAL32.m:61-64): DIR is the $O
  # direction; 1 walks forward from FROM.
  def test_symptom_search_sends_from_and_direction
    RpmsRpc::Symptom.search("COUGH")
    assert_equal [ "COUGH", "1" ], params_sent_to("ORWDAL32 SYMPTOMS")
  end

  # TEMPLATE(DATA,DFN,VSTR,METRIC)^BEHOVM (BEHOVM.m:57): a patient and a
  # visit string, not a location IEN. METRIC is read as $G(METRIC,-1)
  # (QUERY^BEHOVM: BEHOVM.m:95): -1 each vital's default units, 0 US,
  # 1 metric.
  def test_vital_template_sends_dfn_visit_string_and_metric
    RpmsRpc::Vital.template(DFN, VSTR)
    assert_equal [ DFN, VSTR, "-1" ], params_sent_to("BEHOVM TEMPLATE")

    RpmsRpc.client.received_calls.clear
    RpmsRpc::Vital.template(DFN, VSTR, metric: 1)
    assert_equal [ DFN, VSTR, "1" ], params_sent_to("BEHOVM TEMPLATE")
  end

  # PTINFO(DATA,DFN,SLCT)^BEHOPTCX (BEHOPTCX.m:7), GETBDP(RET,DFN)^BEHOPTPC
  # (BEHOPTPC.m:73), CWAD(DATA,DFN)^BEHOCACV (BEHOCACV.m:22). The fetch
  # frames already carried the DFN; the frames that died were the
  # capability probe's, which sent NO parameters. Every frame for these
  # three RPCs now carries a DFN.
  def test_brief_header_never_sends_a_beho_frame_without_a_dfn
    RpmsRpc.client.seed(:patient_ptinfo, DFN, { name: "TESTPATIENT,FIRST", sex: "F", dob_raw: "2860701" })
    RpmsRpc::Patient.brief_header(DFN)

    beho = RpmsRpc.client.received_calls.select { |c| c[:rpc].start_with?("BEHO") }
    refute_empty beho
    beho.each do |call|
      assert_match(/\A\d+\z/, call[:params].first.to_s,
                   "#{call[:rpc]} frame has no DFN in P1: #{call[:params].inspect}")
    end
  end
end
