# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/behavioral_health/reference"

# Tests for RpmsRpc::BehavioralHealth::Reference — AMHG reference-data
# reads (CLN^AMHGTVF, GETPAT^AMHGP, SITE^AMHGU, ADML^AMHGDA).
#
# Fixtures are hand-built from the M source, not round-tripped through our
# own formatter. Per ADR 0003 these are the first evidence. All data synthetic.
class BehavioralHealthReferenceTest < Minitest::Test
  R = RpmsRpc::BehavioralHealth::Reference
  RS = "\x1e"  # $C(30) record separator
  US = "\x1f"  # $C(31) end of recordset

  # GETPAT^AMHGP header, AMHGP.m:15. Thirteen columns, thirteen row fields
  # (AMHGP.m:143). No multi-SET append. No pairs.
  PATIENT_HEADER =
    "T00010IEN^T00030PATIENTNAME^T00015DOB^T00001SEX^T00007CHART^T00009SSN^" \
    "T00010REG^T00030MORE^T00030DOD^T00010AGE^T00001MESSAGEFLAG^T02500MESSAGE^T00001PRF"

  # SITE^AMHGU header is TWO SETs (AMHGU.m:228-229). A reader that stops at
  # the first loses the ten columns from DefCDComm through DeleteOverride —
  # 23 columns, not the 13 a single-line read (or the contracts scan) shows.
  SITE_HEADER =
    "T00010BMXIEN^T00030TypeofVisit^T00030TypeofHS^T00030DefMHLoc^T00030DefMHComm^" \
    "T00030DefMHClinic^T00030DefTypeofContact^T00001AskInterpreter^T00001AllowPCCPrbUp^" \
    "T00030DefSSLoc^T00030DefSSComm^T00030DefSSClinic^T00030DefCDLoc^T00030DefCDComm^" \
    "T00030DefCDClinic^T00030DefOthLoc^T00030DefOthComm^T00030DefOthClinic^T00030DefEHRComm^" \
    "T00001InteractivePCCLink^T00030DefAppt^T00005Lockout^T00001DeleteOverride"

  # ADML^AMHGDA header, AMHGDA.m:15. Ten columns, ten row fields (AMHGDA.m:47).
  ADMIN_HEADER =
    "T00010BMXIEN^T00030SortDate^T00030Date^T00050Program^T00050ActivityCode^" \
    "T00050POV^T00010Time^T00030Provider^T00080ProviderNarrative^T00030LocationofEncounter"

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

  # -- AMHG GET CLINICS (CLN^AMHGTVF) ----------------------------------------

  # CLN^AMHGTVF (AMHGTVF.m:15-16) is a stub: the body is a bare Q. It never
  # assigns RETVAL, never writes a typed header, never writes a data row,
  # never writes $C(31). The #8994 registry lists RETVAL only — no AMHSTR
  # (rpc_contracts.tsv). The broker receives an empty GLOBAL ARRAY.
  #
  # This is not a plain list and not a late-built header. It is nothing.
  # PRV/TOC/LOC/COM in the same routine are the same stub (AMHGTVF.m:9-22).
  def test_clinics_is_empty_because_cln_quits_without_writing_anything
    @mock.seed_text(:amhg_clinics, "", "")

    assert_empty R.clinics, "CLN^AMHGTVF writes no header and no rows (AMHGTVF.m:15-16)"
  end

  # Sending an input actual to CLN(RETVAL) is a second actual on a one-formal
  # entry — YottaDB rejects that with YDB-E-ACTLSTTOOLONG (#198). The call
  # must carry zero input params.
  def test_clinics_sends_no_input_parameter
    @mock.seed_text(:amhg_clinics, "", "")
    R.clinics

    call = @mock.received_calls.find { |c| c[:rpc] == "AMHG GET CLINICS" }
    assert_empty call[:params],
                 "CLN(RETVAL) has no AMHSTR — an input actual is ACTLSTTOOLONG"
  end

  # -- AMHG GET PATIENT (GETPAT^AMHGP) ---------------------------------------

  # Thirteen fields, matching the row built at AMHGP.m:143. IEN is the DFN.
  # SSN is blanked at :134 after the mask is computed. REG emits $G(AMHHD)
  # and MORE emits $G(AMHMORE) — both never assigned. Name is preferred
  # name (GETPREF at :124), not the DPT .01 built on the line above.
  def patient_row(ien:, name: "PATIENT,EXAMPLE", dob: "JAN 15, 1991", sex: "M",
                  chart: "12345", ssn: "", reg: "", more: "", dod: "",
                  age: "34", flag: "", message: "", prf: "0")
    [ ien, name, dob, sex, chart, ssn, reg, more, dod, age, flag, message, prf ].join("^")
  end

  def seed_patients(*rows, param: "42|PATIENT,EXAMPLE|ALL")
    seed(:amhg_patient, param, PATIENT_HEADER, *rows)
  end

  def test_patients_parses_the_thirteen_field_row_and_skips_the_header
    seed_patients(patient_row(ien: "100"))

    patients = R.patients("PATIENT,EXAMPLE", facility: 42)

    assert_equal 1, patients.length, "header and $C(31) terminator are not records"
    p = patients.first
    assert_equal "100", p[:ien], "IEN is the DFN (AMHGP.m:143)"
    assert_equal "PATIENT,EXAMPLE", p[:name]
    assert_equal "JAN 15, 1991", p[:dob], "$$LVDT, not the commented FMTE (AMHGP.m:125)"
    assert_equal "M", p[:sex], "internal sex (AMHGP.m:127)"
    assert_equal "12345", p[:chart]
    assert_nil p[:ssn], "AMHGP.m:134 blanks SSN after computing the mask"
    assert_nil p[:reg], "AMHHD is never assigned — REG is dead (AMHGP.m:143)"
    assert_nil p[:more], "AMHMORE is never assigned — MORE is dead (AMHGP.m:143)"
    assert_nil p[:date_of_death]
    assert_equal "34", p[:age]
    assert_nil p[:message_flag]
    assert_nil p[:message]
    refute p[:prf]
  end

  # AMHGP.m:126 / :135 / :140 — DOB and SSN become **SENSITIVE** when
  # AMHFLAG is set and is not 3 or 4. AGE becomes **SENSITIVE** when
  # AMHFLAG is any truthy value, including 3 and 4. The marker is what
  # the wire sends; we do not hide it.
  def test_patients_surfaces_the_sensitive_marker_the_wire_sends
    seed_patients(patient_row(ien: "100", dob: "**SENSITIVE**", ssn: "**SENSITIVE**",
                              age: "**SENSITIVE**", flag: "1",
                              message: "This record is sensitive."))

    p = R.patients("PATIENT,EXAMPLE", facility: 42).first

    assert_equal "**SENSITIVE**", p[:dob]
    assert_equal "**SENSITIVE**", p[:ssn]
    assert_equal "**SENSITIVE**", p[:age]
    assert_equal "1", p[:message_flag]
    assert_equal "This record is sensitive.", p[:message]
  end

  def test_patients_prf_is_the_zero_one_flag_not_the_narrative
    seed_patients(patient_row(ien: "100", prf: "1"))

    assert R.patients("PATIENT,EXAMPLE", facility: 42).first[:prf],
           "$$PRF^AMHGUVF returns 0/1; the narrative is discarded (AMHGP.m:121, AMHGUVF.m:21)"
  end

  def test_patients_sends_one_pipe_delimited_parameter_with_all_as_default_max
    seed_patients(patient_row(ien: "100"))
    R.patients("PATIENT,EXAMPLE", facility: 42)

    call = @mock.received_calls.find { |c| c[:rpc] == "AMHG GET PATIENT" }
    assert_equal 1, call[:params].length,
                 "AMH rejects multi-actual calls with YDB-E-ACTLSTTOOLONG (#198)"
    assert_equal "42|PATIENT,EXAMPLE|ALL", call[:params].first
  end

  # AMHGP.m:22-23 — empty AMHMT becomes (""-1)=-1, and PATADO quits on
  # AMHCNTR>AMHMT before emitting a row. "ALL" is the only safe default.
  def test_patients_packs_facility_max_and_after_name
    seed_patients(param: "42|PATIENT,E|10|PATIENT,EX")
    R.patients("PATIENT,E", facility: 42, max: 10, after_name: "PATIENT,EX")

    call = @mock.received_calls.find { |c| c[:rpc] == "AMHG GET PATIENT" }
    assert_equal [ "42|PATIENT,E|10|PATIENT,EX" ], call[:params]
  end

  def test_patients_with_no_records_returns_empty
    seed_patients

    assert_empty R.patients("PATIENT,EXAMPLE", facility: 42)
  end

  # -- AMHG GET SITE PARAMETERS (SITE^AMHGU) ---------------------------------

  # Twenty-three fields, matching AMHGU.m:288-289. Sixteen carry an
  # IEN~external pair (R="~" at AMHGU.m:223). AskInterpreter / AllowPCCPrbUp
  # are internals. InteractivePCCLink is forced "1"/"0". DefAppt is
  # external-only. Lockout is the fallback number. DeleteOverride is 1/0.
  def seed_site(ien: "55",
                type_of_visit: "1~OUTPATIENT",
                type_of_hs: "3~ADULT",
                mh_loc: "55~EXAMPLE HEALTH CENTER",
                mh_comm: "9~ON RESERVATION",
                mh_clinic: "17~BH CLINIC",
                type_of_contact: "3~AMBULATORY",
                ask_interpreter: "1",
                allow_pcc: "0",
                ss_loc: "55~EXAMPLE HEALTH CENTER",
                ss_comm: "9~ON RESERVATION",
                ss_clinic: "18~SS CLINIC",
                cd_loc: "56~EXAMPLE CD UNIT",
                cd_comm: "9~ON RESERVATION",
                cd_clinic: "19~CD CLINIC",
                oth_loc: "57~EXAMPLE OTHER SITE",
                oth_comm: "10~OFF RESERVATION",
                oth_clinic: "20~OTHER CLINIC",
                ehr_comm: "9~ON RESERVATION",
                interactive_pcc: "1",
                def_appt: "FOLLOW-UP",
                lockout: "300",
                delete_override: "1")
    row = [ ien, type_of_visit, type_of_hs, mh_loc, mh_comm, mh_clinic,
            type_of_contact, ask_interpreter, allow_pcc, ss_loc, ss_comm,
            ss_clinic, cd_loc, cd_comm, cd_clinic, oth_loc, oth_comm,
            oth_clinic, ehr_comm, interactive_pcc, def_appt, lockout,
            delete_override ].join("^")
    seed(:amhg_site_parameters, ien, SITE_HEADER, row)
  end

  def test_site_parameters_parses_all_twenty_three_columns_not_the_thirteen_a_single_set_would_show
    seed_site

    site = R.site_parameters(55)

    assert_equal "55", site[:ien]
    assert_equal "FOLLOW-UP", site[:default_appointment],
                 "column 21 — only reachable if both header SETs are read (AMHGU.m:228-229)"
    assert_equal "300", site[:lockout]
    assert site[:delete_override], "column 23 — DeleteOverride (AMHGU.m:286, :289)"
  end

  def test_site_parameters_splits_ien_name_pairs_on_the_tilde
    seed_site

    site = R.site_parameters(55)

    assert_equal({ ien: "1", name: "OUTPATIENT" }, site[:type_of_visit])
    assert_equal({ ien: "3", name: "ADULT" }, site[:type_of_hs])
    assert_equal({ ien: "55", name: "EXAMPLE HEALTH CENTER" }, site[:default_mh_location])
    assert_equal({ ien: "9", name: "ON RESERVATION" }, site[:default_mh_community])
    assert_equal({ ien: "17", name: "BH CLINIC" }, site[:default_mh_clinic])
    assert_equal({ ien: "3", name: "AMBULATORY" }, site[:default_type_of_contact])
    assert_equal({ ien: "55", name: "EXAMPLE HEALTH CENTER" }, site[:default_ss_location])
    assert_equal({ ien: "9", name: "ON RESERVATION" }, site[:default_ss_community])
    assert_equal({ ien: "18", name: "SS CLINIC" }, site[:default_ss_clinic])
    assert_equal({ ien: "56", name: "EXAMPLE CD UNIT" }, site[:default_cd_location])
    assert_equal({ ien: "9", name: "ON RESERVATION" }, site[:default_cd_community])
    assert_equal({ ien: "19", name: "CD CLINIC" }, site[:default_cd_clinic])
    assert_equal({ ien: "57", name: "EXAMPLE OTHER SITE" }, site[:default_oth_location])
    assert_equal({ ien: "10", name: "OFF RESERVATION" }, site[:default_oth_community])
    assert_equal({ ien: "20", name: "OTHER CLINIC" }, site[:default_oth_clinic])
    assert_equal({ ien: "9", name: "ON RESERVATION" }, site[:default_ehr_community])
  end

  # AMHGU.m:248 / :252 — AskInterpreter and AllowPCCPrbUp are GET1 "I",
  # not pairs. InteractivePCCLink is forced "1"/"0" (AMHGU.m:283).
  # DefAppt is external-only (AMHGU.m:284).
  def test_site_parameters_flags_and_def_appt_are_not_pairs
    seed_site

    site = R.site_parameters(55)

    assert site[:ask_interpreter]
    refute site[:allow_pcc_problem_update]
    assert site[:interactive_pcc_link]
    assert_equal "FOLLOW-UP", site[:default_appointment]
  end

  def test_site_parameters_sends_one_pipe_delimited_parameter
    seed_site
    R.site_parameters(55)

    call = @mock.received_calls.find { |c| c[:rpc] == "AMHG GET SITE PARAMETERS" }
    assert_equal [ "55" ], call[:params]
  end

  def test_site_parameters_returns_nil_when_the_ien_yields_no_row
    seed(:amhg_site_parameters, "9999", SITE_HEADER)

    assert_nil R.site_parameters(9999)
  end

  # -- AMHG GET ADMIN RECORDS (ADML^AMHGDA) ----------------------------------

  # Ten fields, matching AMHGDA.m:47. No pairs — Program/Activity/Provider/
  # Location/Narrative are external-only. BMXIEN is the 9002011 record IEN.
  # POV is the first AD-xref hit only (AMHGDA.m:38).
  #
  # Inverse-date constants (AMHGDA.m:19-20):
  #   AMHIVB = (9999999-AMHB)+.0001
  #   AMHIVE = (9999999-AMHE)-.9999
  # Same pair as TPL/SFL/INTAKEL/COML. Opposite of GROUPL (AMHGDA.m:107-108)
  # and VISITL (AMHGD.m:22-23), which use +.9999 / -.0001.
  def admin_row(ien:, pov: "DEPRESSIVE DISORDER")
    [ ien, "3250114", "JAN 14, 2025", "ADULT OUTPATIENT", "ADMIN NOTE",
      pov, "30", "THERAPIST,EXAMPLE", "Follow-up documentation",
      "EXAMPLE HEALTH CENTER" ].join("^")
  end

  def seed_admin(*rows)
    seed(:amhg_admin_records, "3250101|3251231|412", ADMIN_HEADER, *rows)
  end

  def test_admin_records_parses_the_ten_field_row_and_skips_the_header
    seed_admin(admin_row(ien: "8801"))

    records = R.admin_records(412, from: "3250101", to: "3251231")

    assert_equal 1, records.length, "header and $C(31) terminator are not records"
    a = records.first
    assert_equal "8801", a[:ien], "BMXIEN is the 9002011 record IEN (AMHGDA.m:47)"
    assert_equal "3250114", a[:sort_date]
    assert_equal "JAN 14, 2025", a[:date]
    assert_equal "ADULT OUTPATIENT", a[:program]
    assert_equal "ADMIN NOTE", a[:activity_code]
    assert_equal "DEPRESSIVE DISORDER", a[:pov]
    assert_equal "30", a[:time]
    assert_equal "THERAPIST,EXAMPLE", a[:provider]
    assert_equal "Follow-up documentation", a[:provider_narrative]
    assert_equal "EXAMPLE HEALTH CENTER", a[:location]
  end

  # AMHGDA.m:38-40 — POV is $O(^AMHRPRO("AD",AMHIEN,0)), the FIRST AD-xref
  # hit only. Not a complete diagnosis list.
  def test_admin_records_pov_column_is_whatever_the_wire_sent_for_the_first_entry
    seed_admin(admin_row(ien: "8801", pov: "DEPRESSIVE DISORDER"))

    assert_equal "DEPRESSIVE DISORDER",
                 R.admin_records(412, from: "3250101", to: "3251231").first[:pov]
  end

  def test_admin_records_are_returned_in_wire_order
    seed_admin(admin_row(ien: "8802"), admin_row(ien: "8801"))

    assert_equal %w[8802 8801],
                 R.admin_records(412, from: "3250101", to: "3251231").map { _1[:ien] }
  end

  def test_admin_records_sends_one_pipe_delimited_parameter_with_provider_not_dfn
    seed_admin(admin_row(ien: "8801"))
    R.admin_records(412, from: "3250101", to: "3251231")

    call = @mock.received_calls.find { |c| c[:rpc] == "AMHG GET ADMIN RECORDS" }
    assert_equal 1, call[:params].length,
                 "AMH rejects multi-actual calls with YDB-E-ACTLSTTOOLONG (#198)"
    assert_equal "3250101|3251231|412", call[:params].first
  end

  def test_admin_records_with_no_records_returns_empty
    seed_admin

    assert_empty R.admin_records(412, from: "3250101", to: "3251231")
  end
end
