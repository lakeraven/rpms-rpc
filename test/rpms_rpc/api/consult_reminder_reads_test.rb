# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"

# What the consult and reminder reads send, how they read the rows the
# pinned build sent (bcer-9.0-20261116-2a9b3fe-ydb: demo patient DFN 2's
# cover-sheet reminders, reminder 9's web sites, the empty consult list),
# and what they refuse before the wire. The build files no consult, so the
# consult rows below are laid out from the routine (GMRCSLM1.m:76-90,
# ORQQCN1.m:63-90), not captured. Proven live in
# test/live/consult_reminder_reads_live_test.rb.
class ConsultReminderReadsTest < Minitest::Test
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

  def test_the_consult_list_sends_its_five_formals_and_reads_the_gui_row
    use("ORQQCN LIST" => [ "12^3261102.1430^p^CARDIOLOGY^Consult^*^Cardiology Cons^55^C" ])
    consults = RpmsRpc::Consult.for_patient(2, start_date: Date.new(2026, 11, 1), end_date: "3261130",
                                               service_ien: 4, status_iens: [ 5, 6 ])
    assert_equal [ "ORQQCN LIST", [ "2", "3261101", "3261130", "4", "5,6" ] ], @client.calls.last
    assert_equal 1, consults.size
    row = consults.first
    assert_equal [ 12, "p", "CARDIOLOGY", "Consult", true, "Cardiology Cons", 55, :consult ],
                 row.values_at(:ien, :status, :service, :kind, :significant_findings, :title, :order_ien, :type)
    assert_equal Time.new(2026, 11, 2, 14, 30), row[:requested_at]
  end

  def test_no_consults_on_file_is_empty_and_other_lines_raise
    use("ORQQCN LIST" => [ "< PATIENT DOES NOT HAVE ANY CONSULTS/REQUESTS  ON FILE. >" ])
    assert_empty RpmsRpc::Consult.for_patient(2)
    use("ORQQCN LIST" => [ "< PATIENT DOES NOT HAVE ANY CONSULTS/REQUESTS  ON FILE. >", "Between Dates: Jan 01, 2026 and Dec 31, 2026" ])
    assert_empty RpmsRpc::Consult.for_patient(2, start_date: "3260101", end_date: "3261231")
    use("ORQQCN LIST" => [ "-1^Patient unknown" ])
    assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Consult.for_patient(2) }
    use("ORQQCN LIST" => [ "something else" ])
    assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Consult.for_patient(2) }
  end

  def test_consult_reads_refuse_bad_ids_before_the_wire
    use
    assert_empty RpmsRpc::Consult.for_patient("2^1")
    assert_empty RpmsRpc::Consult.for_patient(2, status_iens: [ "5^" ])
    assert_nil RpmsRpc::Consult.find(0)
    assert_nil RpmsRpc::Consult.resubmittable("x")
    assert_empty @client.calls
  end

  def test_find_reads_the_zero_node_and_its_linked_notes
    zero = "3261102.1430^2^55^13^4^13^3261102^^9^10^^5^7^3;PROVIDER,TEST^^^C^O^Y"
    use("ORQQCN GET CONSULT" => [ zero, "88^CONSULT NOTE^3261103^^^^^^^^^^^1" ])
    found = RpmsRpc::Consult.find(12)
    assert_equal [ "ORQQCN GET CONSULT", [ "12", "" ] ], @client.calls.last
    assert_equal [ 12, 2, 55, 13, 4, 13, 9, 10, 5, 7, 3, "PROVIDER,TEST", "C", "O", "Y" ],
                 found.values_at(:ien, :patient_dfn, :order_ien, :patient_location_ien, :to_service_ien,
                                 :from_location_ien, :urgency_ien, :place_ien, :status_ien, :last_action_ien,
                                 :sending_provider_duz, :sending_provider, :request_type, :service_rendered,
                                 :significant_findings)
    assert_equal [ { kind: :note, ien: 88, title: "CONSULT NOTE" } ], found[:results]
  end

  def test_find_of_a_consult_not_on_file_is_nil
    use("ORQQCN GET CONSULT" => [ "-1^Invalid consult" ])
    assert_nil RpmsRpc::Consult.find(1)
  end

  def test_resubmittable_reads_the_flag_and_reason
    use("ORQQCN CANEDIT" => [ "0^Invalid Consult Number" ])
    assert_equal({ resubmittable: false, reason: "Invalid Consult Number" }, RpmsRpc::Consult.resubmittable(1))
    use("ORQQCN CANEDIT" => [ "1" ])
    assert_equal({ resubmittable: true, reason: nil }, RpmsRpc::Consult.resubmittable(1))
    use("ORQQCN CANEDIT" => [ "maybe" ])
    assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Consult.resubmittable(1) }
  end

  def test_unevaluated_reads_reminder_iens
    use("ORQQPXRM REMINDERS UNEVALUATED" => %w[212 309 123 211 274])
    assert_equal [ 212, 309, 123, 211, 274 ], RpmsRpc::Reminders.unevaluated(2)
    assert_equal [ "ORQQPXRM REMINDERS UNEVALUATED", [ "2", "" ] ], @client.calls.last
    use("ORQQPXRM REMINDERS UNEVALUATED" => [ "1^212" ])
    assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Reminders.unevaluated(2) }
  end

  def test_categories_read_the_tree_and_the_error_row_raises
    use("ORQQPXRM REMINDER CATEGORIES" => [ "1^C^IMMUNIZATIONS^0^", "2^R^Flu shot^1^9^1" ])
    assert_equal [ { id: 1, kind: :category, name: "IMMUNIZATIONS", parent_id: 0 },
                   { id: 2, kind: :reminder, name: "Flu shot", parent_id: 1, reminder_ien: 9, has_dialog: true } ],
                 RpmsRpc::Reminders.categories(2, 13)
    assert_equal [ "2", "13" ], @client.calls.last[1]
    use("ORQQPXRM REMINDER CATEGORIES" => [ "^Error: no such parameter" ])
    assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Reminders.categories(2) }
  end

  def test_education_topics_read_ien_name_and_print_name
    use("ORQQPXRM EDUCATION SUMMARY" => [ "41^TO-QUIT^Tobacco: quitting" ])
    assert_equal [ { ien: 41, name: "TO-QUIT", print_name: "Tobacco: quitting" } ], RpmsRpc::Reminders.education_topics(211)
    assert_equal [ "ORQQPXRM EDUCATION SUMMARY", [ "211" ] ], @client.calls.last
  end

  def test_web_references_group_descriptions_under_their_site
    use("ORQQPXRM REMINDER WEB" => [ "1^1^http://www.cdc.gov/mmwr/preview/mmwrhtml/mm5351-Immunizationa1.htm^Immunizations",
                                     "2^1^Schedules", "1^2^http://www.ihs.gov/cio/crs/^Clinical Reporting System" ])
    assert_equal [ { url: "http://www.cdc.gov/mmwr/preview/mmwrhtml/mm5351-Immunizationa1.htm", title: "Immunizations", description: [ "Schedules" ] },
                   { url: "http://www.ihs.gov/cio/crs/", title: "Clinical Reporting System", description: [] } ],
                 RpmsRpc::Reminders.web_references(9)
    use("ORQQPXRM REMINDER WEB" => [ "2^1^an orphan description" ])
    assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Reminders.web_references(9) }
  end
end
