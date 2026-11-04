# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/referral"

# The BMC SEARCH REFERRAL and BMC GET REFERRAL reply lines, built piece by
# piece from CRTMSG^BMCRPC4 (FOIA Referred Care Information System,
# BMCRPC4.m), and BMC PRINT REFERRAL's text array (PRINT^BMCRPC5). These are
# routine-derived lines, not captured replies: a live capture is still owed
# (#210, #182).
class ReferralWireTest < Minitest::Test
  DFN = "8791"
  REF = "113251"

  # DETAIL=0, BMCRPC4.m:60-61 (fields from SRCHREF^BMCRPC1, BMCRPC1.m:42).
  SEARCH_LINE = [
    "~`#{REF}",           # 0 REFIEN, sigil-prefixed
    "OCT 01, 2026",       # 1 REFDATE (.01, external)
    "2026-00042",         # 2 REFNMBR (.02)
    DFN,                  # 3 PATIEN (.03 I)
    "DEMO,PATIENT ONE",   # 4 PATNAME (.03 E)
    "12345",              # 5 PATHRN
    "FRANK,STUART A",     # 6 RQSTPRV (.06)
    "MEMORIAL HOSPITAL",  # 7 FCLTYRFT (.0999)
    "OCT 20, 2026",       # 8 APPTDT (AVDOS^BMCRLU)
    "ACTIVE",             # 9 REFSTATUS (.15)
    "CARDIOLOGY CONSULT", # 10 REFPRPS (1201)
    "",                   # 11 DENLRSN (1114)
    "CHS & DIRECT",       # 12 CHSELIG
    "",                   # 13 VAELIG
    "CALL PATIENT",       # 14 SCHNOTES (1301)
    "",                   # 15 SUFFIX (101)
    "FRANK,STUART A",     # 16 C32DATA: 90001.6 .02
    "OCT 02, 2026",       # 17 C32DATA: 90001.6 .01
    "C32",                # 18 C32DATA: 90001.6 .04
    "PENDING",            # 19 REFCNST (1306)
    "OCT 03, 2026",       # 20 REFCNDT (1307)
    "NURSE,TWO",          # 21 REFCNBY (1308)
    "JAN 01, 1960",       # 22 PATDOB
    "FRANK,STUART A",     # 23 PCP
    "OCT 04, 2026"        # 24 ACKDATE
  ].join("^")

  # DETAIL=1, BMCRPC4.m:116-119 (fields from GTRFBYID^BMCRPC1, BMCRPC1.m:62).
  DETAIL_FIELDS = [
    "~`#{REF}", "OCT 01, 2026", "2026-00042", DFN, "DEMO,PATIENT ONE", "12345",
    "201",                     # 6 RQSTPRV, internal (BMCRPC4.m:69)
    "MEMORIAL HOSPITAL", "OCT 20, 2026",
    "APPROVED",                # 9 CHSSTATS (1112)
    "CARDIOLOGY CONSULT", "", "CHS & DIRECT", "", "CALL PATIENT",
    "C",                       # 15 REFTYPE (.04 I)
    "O",                       # 16 VSTTYPE (.14 I)
    "",                        # 17 VSTNMBR (1111)
    "12", "34",                # 18-19 ICDCATID, CPTCATID
    "77",                      # 20 TYPEEXT (vendor for type C)
    "",                        # 21 SUFFIX
    "14",                      # 22 SCHWIDAY (1302)
    "Y", "N", "Y", "N", "N", "Y", "N", "N", "N", "Y", "N", "N", # 23-34 INCL*
    "3~ROUTINE R",             # 35 PRIORITY: IEN~NAME CODE (BMCRPC4.m:49)
    "",                        # 36 PROBLEM
    "",                        # 37 OTHERTYPE
    "<UNKNOWN>",               # 38 OTHERTYPETEXT
    "", "",                    # 39-40 SNOMEDCT, SNOMEDPT
    "PENDING", "OCT 03, 2026", "NURSE,TWO", # 41-43 REFCNST, REFCNDT, REFCNBY
    "ACTIVE",                  # 44 REFSTATUS (.15)
    "",                        # 45 ^BMCREF(REFIEN,22,1,0)
    "5501",                    # 46 VISIT
    "SMITH,CALLER"             # 47 CALLINBY (104)
  ].freeze

  # RDFIELDS (BMCRPC4.m:97,114) is appended to CALLINBY with no caret, then
  # GTRFBYID appends the MEDHX notes (GETMEDHX, BMCRPC1.m:129,143).
  DIAGNOSES = "~`D'~D" \
              "D'~D9001^4411^#{DFN}^#{REF}^R^P^61^I25.10^ATHEROSCLEROTIC HEART DISEASE"
  MED_HX = "~`M'~M" \
           "301^OCT 01, 2026^FRANK,STUART A^CHEST PAIN ON EXERTION~SINCE AUGUST"

  DETAIL_LINE = DETAIL_FIELDS.join("^") + DIAGNOSES + MED_HX

  def teardown
    RpmsRpc.reset!
  end

  def test_search_reads_the_detail_zero_layout
    RpmsRpc.mock! { |m| m.seed_raw_lines(:referral_search, DFN, [ SEARCH_LINE ]) }

    rows = RpmsRpc::Referral.for_patient(DFN)

    assert_equal 1, rows.length
    row = rows.first
    assert_equal REF, row[:ien]
    assert_equal Date.new(2026, 10, 1), row[:date]
    assert_equal "2026-00042", row[:referral_number]
    assert_equal 8791, row[:patient_dfn]
    assert_equal "DEMO,PATIENT ONE", row[:patient_name]
    assert_equal "FRANK,STUART A", row[:provider]
    assert_equal "MEMORIAL HOSPITAL", row[:facility]
    assert_equal "ACTIVE", row[:status]
    assert_equal "CARDIOLOGY CONSULT", row[:purpose]
    assert_equal "C32", row[:c32_document_type]
    assert_equal "OCT 04, 2026", row[:acknowledged_date]
  end

  # Captured from BMC SEARCH REFERRAL over CIA on bcer-9.0-20261029-7c3119b-ydb
  # (rpms-rpc#589): one patient's two referrals, demo data filed by
  # test/live/referral_pending_live_test.rb. CRTMSG files each record in its
  # own node and the broker sends them with nothing between, so both arrive
  # in one line.
  CAPTURED_TWO_RECORDS =
    "~`1^JAN 10, 2001^^990002^BRAVO,ALEX^^^<UNKNOWN>^^ACTIVE^^^DIRECT ONLY^^^^^^^^^^05/08/1965^^" \
    "~`5^FEB 01, 2001^^990002^BRAVO,ALEX^^^<UNKNOWN>^^ACTIVE^^^DIRECT ONLY^^^^^^^^^^05/08/1965^^"

  def test_search_reads_each_record_of_a_line_that_carries_several
    RpmsRpc.mock! { |m| m.seed_raw_lines(:referral_search, "990002", [ CAPTURED_TWO_RECORDS ]) }

    rows = RpmsRpc::Referral.for_patient(990_002)

    assert_equal [ "1", "5" ], rows.map { |r| r[:ien] }
    assert_equal [ Date.new(2001, 1, 10), Date.new(2001, 2, 1) ], rows.map { |r| r[:date] }
    assert_equal [ 990_002, 990_002 ], rows.map { |r| r[:patient_dfn] }
    assert_equal [ "05/08/1965" ] * 2, rows.map { |r| r[:patient_dob] }
  end

  # With no patient and no provider, the routine's date path, under its own
  # "Active/Approved" status screen (BMCRPC1.m:40-47).
  def test_pending_sends_no_patient_the_date_range_and_the_open_status_screen
    mock = RpmsRpc.mock! { |m| m.seed_raw_lines(:referral_search, "", [ CAPTURED_TWO_RECORDS ]) }

    rows = RpmsRpc::Referral.pending(from: Date.new(2001, 1, 1), to: Date.new(2001, 2, 28))

    call = mock.received_calls.find { |c| c[:rpc] == "BMC SEARCH REFERRAL" }
    assert_equal [ "", "", "JAN 01, 2001", "FEB 28, 2001", "", "Active/Approved" ], call[:params]
    assert_equal [ "1", "5" ], rows.map { |r| r[:ien] }
  end

  def test_pending_refuses_a_window_that_is_not_two_ordered_dates
    mock = RpmsRpc.mock!

    assert_raises(ArgumentError) { RpmsRpc::Referral.pending(from: Date.new(2001, 2, 1), to: Date.new(2001, 1, 1)) }
    assert_raises(ArgumentError) { RpmsRpc::Referral.pending(from: "JAN 01, 2001", to: Date.new(2001, 1, 1)) }
    assert_empty mock.received_calls
  end

  def test_detail_reads_the_detail_one_layout
    RpmsRpc.mock! { |m| m.seed_raw_lines(:referral_detail, REF, [ DETAIL_LINE ]) }

    r = RpmsRpc::Referral.find(REF)

    assert_equal REF, r[:ien]
    assert_equal 8791, r[:patient_dfn]
    assert_equal "201", r[:provider_ien]
    assert_equal "APPROVED", r[:chs_status]
    assert_equal "C", r[:type]
    assert_equal "77", r[:referred_to_ien]
    assert_equal "3~ROUTINE R", r[:priority]
    assert_equal "ACTIVE", r[:status]
    assert_equal "5501", r[:visit_ien]
    assert_equal "SMITH,CALLER", r[:called_in_by]
  end

  def test_detail_reads_the_diagnoses_and_notes_sections
    RpmsRpc.mock! { |m| m.seed_raw_lines(:referral_detail, REF, [ DETAIL_LINE ]) }

    r = RpmsRpc::Referral.find(REF)

    assert_equal [ { ien: "9001", icd_ien: "4411", patient_dfn: DFN, referral_ien: REF, type: "R",
                     primary_secondary: "P", narrative_ien: "61", icd_code: "I25.10",
                     narrative: "ATHEROSCLEROTIC HEART DISEASE" } ], r[:diagnoses]
    assert_equal [ { ien: "301", date: "OCT 01, 2026", reviewer: "FRANK,STUART A",
                     text: "CHEST PAIN ON EXERTION\nSINCE AUGUST" } ], r[:notes][:medical_history]
    assert_empty r[:notes][:business_office]
    refute r.key?(:sections)
  end

  # GTRFBYID^BMCRPC1 answers a message, not a record, for an unknown IEN
  # (BMCRPC1.m:55): it is not a referral.
  def test_detail_message_without_the_sigil_is_no_record
    RpmsRpc.mock! { |m| m.seed_raw_lines(:referral_detail, "999", [ "Not a valid Referral Ien" ]) }

    assert_nil RpmsRpc::Referral.find("999")
  end

  # PRINT^BMCRPC5 (BMCRPC5.m:50-64) answers the STANDARD IHS REFERRAL LETTER
  # as a text array, not a success flag.
  def test_print_returns_the_letter_text
    RpmsRpc.mock! do |m|
      m.seed_text(:bmc_print_referral, REF, "STANDARD IHS REFERRAL LETTER\nPATIENT: DEMO,PATIENT ONE")
    end

    assert_equal "STANDARD IHS REFERRAL LETTER\nPATIENT: DEMO,PATIENT ONE", RpmsRpc::Referral.print(REF)
  end
end
