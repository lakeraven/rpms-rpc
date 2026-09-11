# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/behavioral_health/case_management"

# Tests for RpmsRpc::BehavioralHealth::CaseManagement — AMHG case and
# community-activity reads (CML^AMHGD, CM^AMHGDCM, COML^AMHGDA,
# COM^AMHGDCOM).
#
# Fixtures are hand-built from the M source, not round-tripped through our
# own formatter. Per ADR 0003 these are the first evidence. All data synthetic.
class BehavioralHealthCaseManagementTest < Minitest::Test
  CM = RpmsRpc::BehavioralHealth::CaseManagement
  RS = "\x1e"  # $C(30) record separator
  US = "\x1f"  # $C(31) end of recordset

  # CML^AMHGD header, AMHGD.m:129. Eight columns, eight row fields
  # (AMHGD.m:152). No multi-SET append.
  CASE_DATES_HEADER =
    "T00010BMXIEN^T00030SortDate^T00030OpenDate^T00030AdmitDate^T00030ClosedDate^" \
    "T00050Disposition^T00030Program^T00030Provider"

  # CM^AMHGDCM header, AMHGDCM.m:18. Ten columns, ten row fields
  # (AMHGDCM.m:39). No multi-SET append.
  CASE_MGMT_HEADER =
    "T00010BMXIEN^T00030CaseOpen^T00030CaseAdmit^T00030CaseClosed^T00030Disposition^" \
    "T00030Program^T00030Provider^T00030Problem^T00030NextReview^T00250Comment"

  # COML^AMHGDA header, AMHGDA.m:58. Nine columns, nine row fields
  # (AMHGDA.m:92). No multi-SET append.
  COML_HEADER =
    "T00010BMXIEN^T00030SortDate^T00030Date^T00030Provider^T00010Time^" \
    "T00050ActivityCode^T00050POV^T00080ProviderNarrative^T00030LocationofEncounter"

  # COM^AMHGDCOM header is TWO SETs (AMHGDCOM.m:18-19). A reader that stops
  # at the first loses T00010Flag and T00050Clinic — 15 columns, not 13.
  COM_HEADER =
    "T00010BMXIEN^T00050Provider^T00030Program^T00050TypeofContact^T00010StartTime^" \
    "T00010Time^T00010NumberServed^T00030Target^T00030Date^T00050Location^" \
    "T00050CommunityofService^T00060ActivityCode^T00050LocalServiceSite^" \
    "T00010Flag^T00050Clinic"

  def setup
    @mock = RpmsRpc.mock!
  end

  def teardown
    RpmsRpc.reset!
  end

  def seed(mapping, param, header, *rows)
    body = [ header + RS ] + rows.map { |r| r + RS } + [ US ]
    @mock.seed_text(mapping, param, body.join("\n"))
  end

  # -- AMHG GET CASE DATES (CML^AMHGD) ---------------------------------------

  # Eight fields, matching the row built at AMHGD.m:152. Disposition,
  # Program and Provider are IEN~external pairs (R="~" at AMHGD.m:125).
  # The third pipe piece is a patient DFN — CML walks ^AMHPCASE("AA",AMHP)
  # (AMHGD.m:135), not a provider index.
  def case_date_row(ien:,
                    sort_date: "3250114",
                    open_date: "JAN 14, 2025",
                    admit_date: "JAN 15, 2025",
                    closed_date: "",
                    disposition: "",
                    program: "3~ADULT OUTPATIENT",
                    provider: "412~THERAPIST,EXAMPLE")
    [ ien, sort_date, open_date, admit_date, closed_date,
      disposition, program, provider ].join("^")
  end

  def seed_case_dates(*rows)
    seed(:amhg_case_dates, "3250101|3251231|100", CASE_DATES_HEADER, *rows)
  end

  def test_case_dates_parses_the_eight_field_row_and_skips_the_header
    seed_case_dates(case_date_row(ien: "6601",
                                  disposition: "2~COMPLETED TREATMENT"))

    cases = CM.case_dates(100, from: "3250101", to: "3251231")

    assert_equal 1, cases.length, "header and $C(31) terminator are not records"
    c = cases.first
    assert_equal "6601", c[:ien]
    assert_equal "3250114", c[:sort_date]
    assert_equal "JAN 14, 2025", c[:open_date]
    assert_equal "JAN 15, 2025", c[:admit_date]
    assert_nil c[:closed_date]
    assert_equal({ ien: "2", name: "COMPLETED TREATMENT" }, c[:disposition])
    assert_equal({ ien: "3", name: "ADULT OUTPATIENT" }, c[:program])
    assert_equal({ ien: "412", name: "THERAPIST,EXAMPLE" }, c[:provider])
  end

  # AMHGD.m:135-136 walks ^AMHPCASE("AA",AMHP) over INVERSE dates, newest first.
  def test_case_dates_are_returned_in_wire_order_newest_first
    seed_case_dates(case_date_row(ien: "6602"), case_date_row(ien: "6601"))

    assert_equal %w[6602 6601], CM.case_dates(100, from: "3250101", to: "3251231").map { _1[:ien] }
  end

  def test_case_dates_sends_one_pipe_delimited_parameter_with_dfn
    seed_case_dates(case_date_row(ien: "6601"))
    CM.case_dates(100, from: "3250101", to: "3251231")

    call = @mock.received_calls.find { |c| c[:rpc] == "AMHG GET CASE DATES" }
    assert_equal 1, call[:params].length,
                 "AMH rejects multi-actual calls with YDB-E-ACTLSTTOOLONG (#198)"
    assert_equal "3250101|3251231|100", call[:params].first
  end

  def test_case_dates_blank_pairs_are_nil
    seed_case_dates(case_date_row(ien: "6601", program: "", provider: ""))

    c = CM.case_dates(100, from: "3250101", to: "3251231").first

    assert_nil c[:disposition]
    assert_nil c[:program]
    assert_nil c[:provider]
  end

  def test_case_dates_with_no_records_returns_empty
    seed_case_dates

    assert_empty CM.case_dates(100, from: "3250101", to: "3251231")
  end

  # -- AMHG GET CASE MANAGEMENT (CM^AMHGDCM) ---------------------------------

  # Ten fields, matching AMHGDCM.m:39. Disposition, Provider and Problem
  # are IEN~external pairs. Program is external-only — AMHPRGS is computed
  # at AMHGDCM.m:28 and the row emits AMHPRG instead.
  #
  # CaseOpen/Admit/Closed are INTERNAL FileMan dates (AMHGDCM.m:20-22),
  # not the $$LVDT CML sends for the same fields (AMHGD.m:152).
  def seed_case_mgmt(ien: "6601",
                     program: "ADULT OUTPATIENT",
                     comment: "Follow up after group")
    row = [ ien, "3250114", "3250115", "",
            "2~COMPLETED TREATMENT", program,
            "412~THERAPIST,EXAMPLE", "441~MAJOR DEPRESSIVE DISORDER",
            "3250414", comment ].join("^")
    seed(:amhg_case_management, ien, CASE_MGMT_HEADER, row)
  end

  def test_case_management_parses_all_ten_columns
    seed_case_mgmt

    info = CM.case_management(6601)

    assert_equal "6601", info[:ien]
    assert_equal "3250114", info[:case_open], "internal FileMan, not $$LVDT (AMHGDCM.m:20)"
    assert_equal "3250115", info[:case_admit]
    assert_nil info[:case_closed]
    assert_equal({ ien: "2", name: "COMPLETED TREATMENT" }, info[:disposition])
    assert_equal "ADULT OUTPATIENT", info[:program],
                 "external only — AMHPRGS is computed and discarded (AMHGDCM.m:28, :39)"
    assert_equal({ ien: "412", name: "THERAPIST,EXAMPLE" }, info[:provider])
    assert_equal({ ien: "441", name: "MAJOR DEPRESSIVE DISORDER" }, info[:problem])
    assert_equal "3250414", info[:next_review]
    assert_equal "Follow up after group", info[:comment]
  end

  def test_case_management_program_is_not_a_pair
    seed_case_mgmt

    program = CM.case_management(6601)[:program]

    assert_equal "ADULT OUTPATIENT", program
    refute program.is_a?(Hash), "Program is AMHPRG, not AMHPRGS (AMHGDCM.m:39)"
  end

  def test_case_management_sends_one_pipe_delimited_parameter
    seed_case_mgmt
    CM.case_management(6601)

    call = @mock.received_calls.find { |c| c[:rpc] == "AMHG GET CASE MANAGEMENT" }
    assert_equal [ "6601" ], call[:params]
  end

  def test_case_management_returns_nil_when_the_ien_yields_no_row
    seed(:amhg_case_management, "9999", CASE_MGMT_HEADER)

    assert_nil CM.case_management(9999)
  end

  # -- AMHG GET COMMUNITY ACTIVITIES (COML^AMHGDA) ---------------------------

  # Nine fields, matching AMHGDA.m:92. No pairs — Provider/ActivityCode/POV/
  # Location are external-only. R is never even set in this entry
  # (AMHGDA.m:54). The third pipe piece is a PROVIDER IEN that the live
  # filter no longer consults (AMHGDA.m:70-76 commented out).
  def community_list_row(ien:,
                         pov: "PREVENTION EDUCATION",
                         provider: "THERAPIST,EXAMPLE")
    [ ien, "3250114", "JAN 14, 2025", provider, "60",
      "COMMUNITY EDUCATION", pov, "School assembly on coping",
      "EXAMPLE HEALTH CENTER" ].join("^")
  end

  def seed_community_list(*rows)
    seed(:amhg_community_activities, "3250101|3251231|412", COML_HEADER, *rows)
  end

  def test_community_activities_parses_the_nine_field_row_and_skips_the_header
    seed_community_list(community_list_row(ien: "9901"))

    rows = CM.community_activities(412, from: "3250101", to: "3251231")

    assert_equal 1, rows.length, "header and $C(31) terminator are not records"
    r = rows.first
    assert_equal "9901", r[:ien]
    assert_equal "3250114", r[:sort_date]
    assert_equal "JAN 14, 2025", r[:date]
    assert_equal "THERAPIST,EXAMPLE", r[:provider]
    assert_equal "60", r[:time]
    assert_equal "COMMUNITY EDUCATION", r[:activity_code]
    assert_equal "PREVENTION EDUCATION", r[:pov]
    assert_equal "School assembly on coping", r[:provider_narrative]
    assert_equal "EXAMPLE HEALTH CENTER", r[:location]
  end

  # AMHGDA.m:83-85 — POV is $O(^AMHRPRO("AD",AMHIEN,0)), the FIRST POV only.
  def test_community_activities_pov_column_is_whatever_the_wire_sent_for_the_first_entry
    seed_community_list(community_list_row(ien: "9901", pov: "PREVENTION EDUCATION"))

    assert_equal "PREVENTION EDUCATION",
                 CM.community_activities(412, from: "3250101", to: "3251231").first[:pov]
  end

  # AMHGDA.m:66-67 walks ^AMHREC("AB") over INVERSE dates, newest first.
  def test_community_activities_are_returned_in_wire_order_newest_first
    seed_community_list(community_list_row(ien: "9902"), community_list_row(ien: "9901"))

    assert_equal %w[9902 9901],
                 CM.community_activities(412, from: "3250101", to: "3251231").map { _1[:ien] }
  end

  def test_community_activities_sends_one_pipe_delimited_parameter_with_provider
    seed_community_list(community_list_row(ien: "9901"))
    CM.community_activities(412, from: "3250101", to: "3251231")

    call = @mock.received_calls.find { |c| c[:rpc] == "AMHG GET COMMUNITY ACTIVITIES" }
    assert_equal 1, call[:params].length,
                 "AMH rejects multi-actual calls with YDB-E-ACTLSTTOOLONG (#198)"
    assert_equal "3250101|3251231|412", call[:params].first
  end

  def test_community_activities_with_no_records_returns_empty
    seed_community_list

    assert_empty CM.community_activities(412, from: "3250101", to: "3251231")
  end

  # -- AMHG GET COMMUNITY ACTIVITY (COM^AMHGDCOM) ----------------------------

  # Fifteen fields, matching AMHGDCOM.m:59. Seven carry an IEN~external pair
  # (R="~" at AMHGDCOM.m:14). Program is external-only. StartTime is blanked
  # at :37. Date is $$VCDT, not the $$LVDT COML sends for the same field.
  def seed_community_activity(start_time: "",
                              location: "55~EXAMPLE HEALTH CENTER",
                              community: "9~ON RESERVATION")
    row = [ "9901", "412~THERAPIST,EXAMPLE", "ADULT OUTPATIENT",
            "3~COMMUNITY", start_time, "60", "25", "YOUTH",
            "2025,01,14,12,0", location, community,
            "12~COMMUNITY EDUCATION", "4~SCHOOL SITE", "1",
            "17~BH CLINIC" ].join("^")
    seed(:amhg_community_activity, "9901", COM_HEADER, row)
  end

  def test_community_activity_parses_all_fifteen_columns_not_the_thirteen_a_single_set_would_show
    seed_community_activity

    info = CM.community_activity(9901)

    assert_equal "9901", info[:ien]
    assert_equal "1", info[:flag],
                 "column 14 — only reachable if both header SETs are read (AMHGDCOM.m:18-19)"
    assert_equal({ ien: "17", name: "BH CLINIC" }, info[:clinic],
                 "column 15 — same second SET")
  end

  def test_community_activity_splits_ien_name_pairs_on_the_tilde
    seed_community_activity

    info = CM.community_activity(9901)

    assert_equal({ ien: "412", name: "THERAPIST,EXAMPLE" }, info[:provider])
    assert_equal({ ien: "3", name: "COMMUNITY" }, info[:type_of_contact])
    assert_equal({ ien: "55", name: "EXAMPLE HEALTH CENTER" }, info[:location])
    assert_equal({ ien: "9", name: "ON RESERVATION" }, info[:community_of_service])
    assert_equal({ ien: "12", name: "COMMUNITY EDUCATION" }, info[:activity])
    assert_equal({ ien: "4", name: "SCHOOL SITE" }, info[:local_service_site])
    assert_equal({ ien: "17", name: "BH CLINIC" }, info[:clinic])
  end

  def test_community_activity_program_is_not_a_pair
    seed_community_activity

    assert_equal "ADULT OUTPATIENT", CM.community_activity(9901)[:program]
  end

  # AMHGDCOM.m:37 assigns AMHST="" with the $P(...,"@",2) extract commented
  # out. Dead column; nil, not "".
  def test_start_time_is_always_nil_because_the_wire_blanks_it
    seed_community_activity(start_time: "")

    assert_nil CM.community_activity(9901)[:start_time]
  end

  # COM formats the date through $$VCDT^AMHGU (AMHGDCOM.m:24) — "YR,MO,DY,HR,MN"
  # — while COML emits $$LVDT of the date-only piece (AMHGDA.m:80, :92).
  def test_community_activity_date_is_vcdt_not_lvdt
    seed_community_activity

    assert_equal "2025,01,14,12,0", CM.community_activity(9901)[:date]
    assert_equal "60", CM.community_activity(9901)[:time]
    assert_equal "25", CM.community_activity(9901)[:number_served]
    assert_equal "YOUTH", CM.community_activity(9901)[:target]
  end

  def test_community_activity_sends_one_pipe_delimited_parameter
    seed_community_activity
    CM.community_activity(9901)

    call = @mock.received_calls.find { |c| c[:rpc] == "AMHG GET COMMUNITY ACTIVITY" }
    assert_equal [ "9901" ], call[:params]
  end

  def test_community_activity_returns_nil_when_the_ien_yields_no_row
    seed(:amhg_community_activity, "9999", COM_HEADER)

    assert_nil CM.community_activity(9999)
  end
end
