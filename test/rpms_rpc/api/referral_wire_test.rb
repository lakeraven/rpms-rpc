# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc"
require "rpms_rpc/api/referral"
require_relative "../captured_replies"

# The BMC SEARCH REFERRAL and BMC GET REFERRAL reply lines (CRTMSG^BMCRPC4,
# FOIA Referred Care Information System, BMCRPC4.m) and BMC PRINT REFERRAL's
# text array (PRINT^BMCRPC5). Every reply is the build's
# (test/fixtures/captured_replies/referral-wire.yml), captured as PROFILE,MD on
# a fresh throwaway container after filing three referrals: 1, a CHS referral
# for demo patient 990001 with its provider, vendor, priority, purpose,
# scheduling notes and documents to include; 2 and 3, two plain referrals for
# demo patient 990002. Each test checks the gem sent exactly the recorded calls.
#
# No referral carries a diagnosis or a note: with an RCIS DIAGNOSIS on file
# BMC GET REFERRAL faults on this build (https://github.com/lakeraven/openrpms/issues/1271),
# so the D and M sections are read here only as the build sends them empty.
class ReferralWireTest < Minitest::Test
  SLUG = "referral-wire"

  def teardown
    RpmsRpc.reset!
  end

  def replay_flow(name)
    @client = CapturedReplies::ReplayCiaClient.new(CapturedReplies.flow_script(SLUG, name))
    RpmsRpc.configure { |cfg| cfg.client = @client }
  end

  def sent = @client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params] ] }

  # DETAIL=0, BMCRPC4.m:60-61 (fields from SRCHREF^BMCRPC1, BMCRPC1.m:42).
  def test_search_reads_the_detail_zero_layout
    replay_flow("search_full")

    rows = RpmsRpc::Referral.for_patient(990_001)

    assert_equal CapturedReplies.flow_calls(SLUG, "search_full"), sent
    assert_equal 1, rows.length
    row = rows.first
    assert_equal "1", row[:ien]
    assert_equal Date.new(2026, 11, 1), row[:date]
    assert_equal "9000000000101", row[:referral_number]
    assert_equal 990_001, row[:patient_dfn]
    assert_equal "ALPHA,CASEY", row[:patient_name]
    assert_equal "PROFILE,MD", row[:provider]
    assert_equal "UNSPECIFIED", row[:facility]
    assert_equal "ACTIVE", row[:status]
    assert_equal "CARDIOLOGY CONSULT", row[:purpose]
    assert_equal "CALL PATIENT", row[:scheduling_notes]
    assert_equal "DIRECT ONLY", row[:chs_eligibility]
    assert_equal "05/26/1952", row[:patient_dob]
    assert_nil row[:c32_document_type]
  end

  # CRTMSG files each record in its own node and the broker sends them with
  # nothing between, so a patient's two referrals arrive in one line.
  def test_search_reads_each_record_of_a_line_that_carries_several
    replay_flow("search_two")

    rows = RpmsRpc::Referral.for_patient(990_002)

    assert_equal [ "2", "3" ], rows.map { |r| r[:ien] }
    assert_equal [ Date.new(2026, 11, 1), Date.new(2026, 11, 2) ], rows.map { |r| r[:date] }
    assert_equal [ 990_002, 990_002 ], rows.map { |r| r[:patient_dfn] }
    assert_equal [ "05/08/1965" ] * 2, rows.map { |r| r[:patient_dob] }
  end

  # With no patient and no provider, the routine's date path, under its own
  # "Active/Approved" status screen (BMCRPC1.m:40-47).
  def test_pending_sends_no_patient_the_date_range_and_the_open_status_screen
    replay_flow("pending")

    rows = RpmsRpc::Referral.pending(from: Date.new(2026, 11, 1), to: Date.new(2026, 11, 30))

    assert_equal [ [ "BMC SEARCH REFERRAL", [ "", "", "NOV 01, 2026", "NOV 30, 2026", "", "Active/Approved" ] ] ], sent
    assert_equal [ "1", "2", "3" ], rows.map { |r| r[:ien] }
  end

  def test_pending_refuses_a_window_that_is_not_two_ordered_dates
    @client = CapturedReplies::ReplayCiaClient.new({})
    RpmsRpc.configure { |cfg| cfg.client = @client }

    assert_raises(ArgumentError) { RpmsRpc::Referral.pending(from: Date.new(2026, 11, 2), to: Date.new(2026, 11, 1)) }
    assert_raises(ArgumentError) { RpmsRpc::Referral.pending(from: "NOV 01, 2026", to: Date.new(2026, 11, 1)) }
    assert_empty @client.calls
  end

  # DETAIL=1, BMCRPC4.m:116-119 (fields from GTRFBYID^BMCRPC1, BMCRPC1.m:62).
  def test_detail_reads_the_detail_one_layout
    replay_flow("find_full")

    r = RpmsRpc::Referral.find("1")

    assert_equal CapturedReplies.flow_calls(SLUG, "find_full"), sent
    assert_equal "1", r[:ien]
    assert_equal 990_001, r[:patient_dfn]
    assert_equal "206", r[:provider_ien]
    assert_equal "PENDING", r[:chs_status]
    assert_equal "C", r[:type]
    assert_equal "O", r[:visit_type]
    assert_equal "1", r[:referred_to_ien], "the vendor, for a CHS referral"
    assert_equal "14", r[:schedule_within_days]
    assert_equal "YES", r[:include_pcc_visit_form]
    assert_equal "YES", r[:include_health_summary]
    assert_equal "20~3 ", r[:priority]
    assert_equal "<UNKNOWN>", r[:other_type]
    assert_equal "ACTIVE", r[:status]
  end

  def test_detail_reads_the_empty_diagnoses_and_notes_sections
    replay_flow("find_full")

    r = RpmsRpc::Referral.find("1")

    assert_equal [], r[:diagnoses]
    assert(r[:notes].values.all?(&:empty?), r[:notes].inspect)
    assert_includes r[:notes].keys, :medical_history
    refute r.key?(:sections)
  end

  # PRINT^BMCRPC5 (BMCRPC5.m:50-64) answers the referral letter as a text
  # array, not a success flag.
  def test_print_returns_the_letter_text
    replay_flow("print_plain")

    letter = RpmsRpc::Referral.print("2")

    assert_equal CapturedReplies.flow_calls(SLUG, "print_plain"), sent
    assert_includes letter, "Referral for Contract Professional Services"
    assert_includes letter, "Patient Name:  BRAVO,ALEX"
    assert_includes letter, "Referral: 9000000000102"
  end

  def test_print_of_a_referral_not_on_file_is_the_routines_message
    replay_flow("print_not_found")

    assert_equal "No referral information was found.", RpmsRpc::Referral.print("999").strip
  end
end
