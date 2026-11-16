# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"

# What the PCC V-file reads send, how they read the rows the pinned build
# sent (bcer-9.0-20261116-2a9b3fe-ydb, demo patient DFN 4, visit 1), and
# what they refuse before the wire. Each read is proven against its V file
# live (test/live/pcc_vfile_reads_live_test.rb).
class PccVfileReadsTest < Minitest::Test
  EXAM = "E^FOOT INSPECTION^09/02/2026^NORMAL/NEGATIVE^^MANAGER,SYSTEM^DEMO IHS CLINIC^4^7819^28^1^4^E^1^09/02/2026"
  FACTOR = "ACTIVITY LEVEL^ACTIVE^08/26/2026^^^2^1^84^^1^09/02/2026^^^0"
  EDUCATION = "IMMUNIZATIONS-LITERATURE^09/02/2026^GOOD^MANAGER,SYSTEM^^1^^^^^^1^DEMO IHS CLINIC^4^4^4126^7819^4^E^^^^^RECEPTIVE^No Code Selected^09/02/2026"
  POV = "1^08/25/2026^000012^DEMO IHS CLINIC^E11.9^^TYPE 2 DIABETES MELLITUS^^^^^^^^~^SECONDARY^^1^0^^^^||^^^Type 2 diabetes mellitus without complications^503126^^^|"

  class RecordingClient
    attr_reader :calls

    def initialize(replies) = (@replies = replies) && (@calls = [])

    def call_rpc(name, *params)
      @calls << [ name, params ]
      @replies.fetch(name, [])
    end

    def create_context(*) = true
    def current_context = "CIAV VUECENTRIC"
  end

  def use(replies = {})
    @client = RecordingClient.new(replies)
    RpmsRpc.configure { |cfg| cfg.client = @client }
  end

  def teardown
    RpmsRpc.reset!
  end

  def test_exams_split_exam_rows_from_refusals
    use("BGOVEXAM GET" => [ EXAM, "R^PAP SMEAR^01/02/2026^PATIENT REFUSED" ])
    read = RpmsRpc::ExamComponent.for_patient(4)
    assert_equal [ "BGOVEXAM GET", [ "4" ] ], @client.calls.last
    exam = read[:exams].first
    assert_equal [ "FOOT INSPECTION", "NORMAL/NEGATIVE", 28, 1, 4, true ],
                 exam.values_at(:exam, :result, :exam_ien, :ien, :visit_ien, :visit_locked)
    assert_equal Date.new(2026, 9, 2), exam[:visit_date]
    assert_equal [ "R^PAP SMEAR^01/02/2026^PATIENT REFUSED" ], read[:refusals]
  end

  def test_health_factors_send_patient_learn_flag_and_no_entry
    use("BGOVHF GET" => [ FACTOR ])
    factor = RpmsRpc::HealthFactor.for_patient(4).first
    assert_equal [ "BGOVHF GET", [ "4^^" ] ], @client.calls.last
    assert_equal [ "ACTIVITY LEVEL", "ACTIVE", 2, 1, 84 ], factor.values_at(:category, :factor, :visit_ien, :ien, :factor_ien)
    RpmsRpc::HealthFactor.for_patient(4, learn_only: true)
    assert_equal [ "4^1^" ], @client.calls.last[1]
  end

  def test_education_reads_the_row_and_filters_by_visit
    use("BGOVPED GET" => [ EDUCATION ])
    ed = RpmsRpc::PatientEducation.for_patient(4, visit_ien: 4).first
    assert_equal [ "BGOVPED GET", [ "4^4" ] ], @client.calls.last
    assert_equal [ "IMMUNIZATIONS-LITERATURE", "GOOD", 4, 4, 4126, 4, "RECEPTIVE" ],
                 ed.values_at(:topic, :level, :ien, :visit_ien, :topic_ien, :provider_ien, :readiness_to_learn)
    assert_equal Date.new(2026, 9, 2), ed[:entered_date]
  end

  def test_a_visits_diagnoses_read_the_detailed_row
    use("BGOVPOV GET" => [ POV ])
    pov = RpmsRpc::Pov.for_visit(1).first
    assert_equal [ "BGOVPOV GET", [ "1^^" ] ], @client.calls.last
    assert_equal [ 1, "E11.9", "TYPE 2 DIABETES MELLITUS", "SECONDARY", 1, false, 503_126 ],
                 pov.values_at(:ien, :icd_code, :narrative, :primary_or_secondary, :visit_ien, :visit_locked, :icd_ien)
  end

  def test_a_refused_read_raises_rather_than_reading_as_none
    use("BGOVHF GET" => [ "-1^Missing patient" ], "BGOVPOV GET" => [ "-1002^Visit not found" ])
    assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::HealthFactor.for_patient(4) }
    assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Pov.for_visit(1) }
  end

  def test_invalid_ids_send_nothing
    use
    assert_equal({ exams: [], refusals: [] }, RpmsRpc::ExamComponent.for_patient(nil))
    assert_empty RpmsRpc::HealthFactor.for_patient("0")
    assert_empty RpmsRpc::PatientEducation.for_patient(4, visit_ien: "4^1")
    assert_empty RpmsRpc::Pov.for_visit("")
    assert_empty @client.calls
  end
end
