# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"

# What the delayed-events, order-details, clinical-indication,
# problem-linked-education, activity-time and postings reads send, how they
# read the rows the pinned build sent (bcer-9.0-20261116-2a9b3fe-ydb: demo
# patient DFN 4's order, coded problems, visit 4's activity time and
# clinical warning, visit 2's education, DFN 990003's record flag), and what
# they refuse before the wire. The build has no delayed event, so that row
# is laid out from the routine (PAT^OREVNTX). Proven live in
# test/live/order_visit_posting_reads_live_test.rb.
class OrderVisitPostingReadsTest < Minitest::Test
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

  def test_delayed_events_drop_the_count_line
    use("OREVNTX PAT" => [ "1", "12^Delayed admission to medicine" ])
    assert_equal [ { event_ien: 12, text: "Delayed admission to medicine" } ], RpmsRpc::Order.delayed_events(4)
    assert_equal [ "OREVNTX PAT", [ "4" ] ], @client.calls.last
    use("OREVNTX PAT" => [])
    assert_empty RpmsRpc::Order.delayed_events(4)
  end

  def test_details_send_the_order_list_and_read_header_and_text
    use("ORWORR GET4LST" => [ "~1;1^13^3261116.033^^^11^2^^^206^PROFILE,MD^^0^^^AP1234563^^^DEMO IHS CLINIC:3^^0^0",
                              "t>> Ambulate in hallway twice daily as tolerated. *UNSIGNED*", "t" ])
    details = RpmsRpc::Order.summaries([ 1 ])
    assert_equal [ "ORWORR GET4LST", [ "", "", { "1" => "1" } ] ], @client.calls.last
    assert_equal({ order_id: "1;1", display_group_ien: 13, ordered_at: Time.new(2026, 11, 16, 3, 30), start_at: nil, stop_at: nil,
                   status_ien: 11, signature_status: "2", provider_duz: 206, provider: "PROFILE,MD", flagged: false,
                   location: "DEMO IHS CLINIC", location_ien: 3, text: [ ">> Ambulate in hallway twice daily as tolerated. *UNSIGNED*" ] },
                 details.first)
    use("ORWORR GET4LST" => [ "something" ])
    assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Order.summaries([ 1 ]) }
    assert_empty RpmsRpc::Order.summaries([ "1^2" ])
    assert_empty RpmsRpc::Order.summaries([])
  end

  def test_clinical_indications_read_source_and_codes
    use("ORWDXIHS CLININD" => [ "Acute bronchitis | ^POV^J20.9^3^10509002", "Type 2 diabetes mellitus | ^PL^E11.9^4^44054006" ])
    rows = RpmsRpc::Order.clinical_indications(4, visit_ien: 4)
    assert_equal [ "ORWDXIHS CLININD", [ "4", "4", "", "" ] ], @client.calls.last
    assert_equal({ name: "Acute bronchitis |", source: :visit_diagnosis, icd: "J20.9", problem_ien: 3, snomed: "10509002" }, rows.first)
    assert_equal :problem_list, rows.last[:source]
    calls = @client.calls.size
    assert_empty RpmsRpc::Order.clinical_indications(4, visit_ien: "4;1")
    assert_equal calls, @client.calls.size
  end

  def test_problem_linked_education_reads_the_row
    use("BGOVPED2 GETPVED" => [ "3^Acute bronchitis-EXERCISE^09/03/2026^4^MANAGER,SYSTEM^2^Acute bronchitis^EXERCISE^FAIR^5^DISTRACTION^" ])
    assert_equal [ { problem_ien: 3, topic: "Acute bronchitis-EXERCISE", documented_on: Date.new(2026, 9, 3), provider_duz: 4,
                     provider: "MANAGER,SYSTEM", ien: 2, code: "Acute bronchitis", subtopic: "EXERCISE", level: "FAIR", minutes: 5,
                     readiness_to_learn: "DISTRACTION", mnemonic: nil } ],
                 RpmsRpc::PatientEducation.problem_linked(2)
    assert_equal [ "BGOVPED2 GETPVED", [ "2" ] ], @client.calls.last
  end

  def test_activity_time_reads_the_entry_and_none_is_nil
    use("BGOVTM GET" => [ "1^30^30" ])
    assert_equal({ ien: 1, activity_minutes: 30, travel_minutes: 30 }, RpmsRpc::Encounter.activity_time(4, 4))
    assert_equal [ "BGOVTM GET", [ "4^4" ] ], @client.calls.last
    use("BGOVTM GET" => [ "0^0^0" ])
    assert_nil RpmsRpc::Encounter.activity_time(2, 4)
    use("BGOVTM GET" => [ "-1103^Provider not found." ])
    assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Encounter.activity_time(2, 4) }
  end

  def test_postings_read_tiu_rows_and_flags
    use("BEHOCACV LIST" => [ "^A^ALLERGIES^Known allergies^", "1^W^CLINICAL WARNING^^3260828.0126^", "1^F^BEHAVIORAL^BEHAVIORAL^3261116.032726^1" ])
    assert_equal [ { kind: :allergies, ien: nil, title: "ALLERGIES", modifier: "Known allergies", date: nil },
                   { kind: :clinical_warning, ien: 1, title: "CLINICAL WARNING", modifier: nil, date: Time.new(2026, 8, 28, 1, 26) },
                   { kind: :record_flag, ien: 1, title: "BEHAVIORAL", modifier: "BEHAVIORAL", date: Time.new(2026, 11, 16, 3, 27, 26) } ],
                 RpmsRpc::Patient.postings(4)
    use("BEHOCACV LIST" => [ "1^Z^SOMETHING^^^" ])
    assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Patient.postings(4) }
  end
end
