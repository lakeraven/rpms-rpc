# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/behavioral_health/groups"

# Tests for RpmsRpc::BehavioralHealth::Groups — AMHG group-encounter reads
# (GROUPL^AMHGDA, ENC/PAT/CPT/EDU/POV/SOAP/SP^AMHGDGP).
#
# Fixtures are hand-built from the M source, not round-tripped through our
# own formatter. Per ADR 0003 these are the first evidence. All data synthetic.
class BehavioralHealthGroupsTest < Minitest::Test
  G = RpmsRpc::BehavioralHealth::Groups
  RS = "\x1e"  # $C(30) record separator
  US = "\x1f"  # $C(31) end of recordset

  # GROUPL^AMHGDA header, AMHGDA.m:103. Twelve columns, twelve row fields
  # (AMHGDA.m:137). No multi-SET append.
  GROUPS_HEADER =
    "T00010BMXIEN^T00030SortDate^T00030Date^T00030GroupName^T00050ActivityCode^" \
    "T00030Program^T00030Clinic^T00030Provider^T00030ContactType^T00080POV^" \
    "T00001Signed^T00030LocationofEncounter"

  # ENC^AMHGDGP header is TWO SETs (AMHGDGP.m:17-18). A reader that stops at
  # the first loses T00250ChiefComplaint — 13 columns, not 12.
  ENC_HEADER =
    "T00010BMXIEN^T00030PrimaryProvider^T00030Program^T00030GroupName^T00030Clinic^" \
    "T00030TypeofContact^T00030EncounterLocation^T00020EncounterDate^T00010ArrivalTime^" \
    "T00050CommofService^T00050Activity^T00010ActivityTime^T00250ChiefComplaint"

  PAT_HEADER =
    "T00010BMXIEN^T00010PatientIEN^T00010AMHREC^T00030PatientName^T00001Sex^" \
    "T00010Age^T00020DOB^T00010Chart^T00030DOD"

  CPT_HEADER =
    "T00010BMXIEN^T00010Code^T00050Narrative^T00010Quantity^T00010Mod1IEN^" \
    "T00010Mod1^T00010Mod2IEN^T00010Mod2"

  EDU_HEADER =
    "T00010BMXIEN^T00030EducationTopic^T00010TimeSpent^T00030LevelOfUnderstanding^" \
    "T00100Comment^T00050CPT^T00030Status^T00030Goal^T00050Provider"

  POV_HEADER = "T00010BMXIEN^T00010Code^T00100Narrative"

  SOAP_HEADER = "T00250Soap"

  SP_HEADER = "T00010BMXIEN^T00030Provider"

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

  # -- AMHG GET GROUPS (GROUPL^AMHGDA) ---------------------------------------

  # Twelve fields, matching the row built at AMHGDA.m:137. The third pipe
  # piece is a PROVIDER IEN used for visibility (AMHGDA.m:115-119), not a
  # patient DFN — GROUPL walks ^AMHGROUP("AINV"), not a patient index.
  def group_row(ien:, signed_marker:, pov: "DEPRESSIVE DISORDER")
    [ ien, "3250114", "JAN 14, 2025", "ADULT SKILLS GROUP", "GROUP THERAPY",
      "ADULT OUTPATIENT", "BH CLINIC", "THERAPIST,EXAMPLE", "AMBULATORY",
      pov, signed_marker, "EXAMPLE HEALTH CENTER" ].join("^")
  end

  def seed_groups(*rows)
    seed(:amhg_group_list, "3250101|3251231|412", GROUPS_HEADER, *rows)
  end

  def test_groups_parses_the_twelve_field_row_and_skips_the_header
    seed_groups(group_row(ien: "7701", signed_marker: ""))

    groups = G.groups(412, from: "3250101", to: "3251231")

    assert_equal 1, groups.length, "header and $C(31) terminator are not records"
    g = groups.first
    assert_equal "7701", g[:ien]
    assert_equal "3250114", g[:sort_date]
    assert_equal "JAN 14, 2025", g[:date]
    assert_equal "ADULT SKILLS GROUP", g[:group_name]
    assert_equal "GROUP THERAPY", g[:activity_code]
    assert_equal "ADULT OUTPATIENT", g[:program]
    assert_equal "BH CLINIC", g[:clinic]
    assert_equal "THERAPIST,EXAMPLE", g[:provider]
    assert_equal "AMBULATORY", g[:contact_type]
    assert_equal "DEPRESSIVE DISORDER", g[:pov]
    assert_equal "EXAMPLE HEALTH CENTER", g[:location]
  end

  # AMHGDA.m:133 — AMHESIG is "*" when field .18 is FALSE, i.e. the star
  # means NOT signed. Same inversion as VISITL^AMHGD (AMHGD.m:47).
  def test_groups_signed_is_inverted_on_the_wire
    seed_groups(group_row(ien: "7701", signed_marker: "*"),
                group_row(ien: "7702", signed_marker: ""))

    unsigned, signed = G.groups(412, from: "3250101", to: "3251231")

    refute unsigned[:signed], '"*" in the Signed column means NOT signed (AMHGDA.m:133)'
    assert signed[:signed], "empty Signed column means the group is signed"
  end

  # AMHGDA.m:130-132 — POV is $G(^AMHGROUP(ien,21,1,0)), the FIRST POV only.
  # The POV tab (POV^AMHGDGP) walks the whole multiple. The list column is
  # not a complete diagnosis list.
  def test_groups_pov_column_is_whatever_the_wire_sent_for_the_first_entry
    seed_groups(group_row(ien: "7701", signed_marker: "", pov: "DEPRESSIVE DISORDER"))

    assert_equal "DEPRESSIVE DISORDER", G.groups(412, from: "3250101", to: "3251231").first[:pov]
  end

  # AMHGDA.m:110-111 walks ^AMHGROUP("AINV") over INVERSE dates, newest first.
  def test_groups_are_returned_in_wire_order_newest_first
    seed_groups(group_row(ien: "7702", signed_marker: ""),
                group_row(ien: "7701", signed_marker: ""))

    assert_equal %w[7702 7701], G.groups(412, from: "3250101", to: "3251231").map { _1[:ien] }
  end

  def test_groups_sends_one_pipe_delimited_parameter_with_provider_not_dfn
    seed_groups(group_row(ien: "7701", signed_marker: ""))
    G.groups(412, from: "3250101", to: "3251231")

    call = @mock.received_calls.find { |c| c[:rpc] == "AMHG GET GROUPS" }
    assert_equal 1, call[:params].length,
                 "AMH rejects multi-actual calls with YDB-E-ACTLSTTOOLONG (#198)"
    assert_equal "3250101|3251231|412", call[:params].first
  end

  def test_groups_with_no_records_returns_empty
    seed_groups

    assert_empty G.groups(412, from: "3250101", to: "3251231")
  end

  # -- AMHG GET GROUP INFORMATION (ENC^AMHGDGP) ------------------------------

  # Thirteen fields, matching AMHGDGP.m:55. Six carry an IEN~external pair
  # (R="~" at AMHGDGP.m:13). Program is external-only — AMHPRGS is NEW'd at
  # :20 and never assigned. ArrivalTime is blanked at :43.
  def seed_group_info(arrival: "", location: "55~EXAMPLE HEALTH CENTER", community: "9~ON RESERVATION")
    row = [ "7701", "412~THERAPIST,EXAMPLE", "ADULT OUTPATIENT", "ADULT SKILLS GROUP",
            "17~BH CLINIC", "3~AMBULATORY", location, "2025,01,14,12,0", arrival,
            community, "12~GROUP THERAPY", "60",
            "Low mood and sleep disruption" ].join("^")
    seed(:amhg_group_information, "7701", ENC_HEADER, row)
  end

  def test_group_information_parses_all_thirteen_columns_not_the_twelve_a_single_set_would_show
    seed_group_info

    info = G.group_information(7701)

    assert_equal "7701", info[:ien]
    assert_equal "Low mood and sleep disruption", info[:chief_complaint],
                 "column 13 — only reachable if both header SETs are read (AMHGDGP.m:17-18)"
  end

  def test_group_information_splits_ien_name_pairs_on_the_tilde
    seed_group_info

    info = G.group_information(7701)

    assert_equal({ ien: "412", name: "THERAPIST,EXAMPLE" }, info[:primary_provider])
    assert_equal({ ien: "17", name: "BH CLINIC" }, info[:clinic])
    assert_equal({ ien: "3", name: "AMBULATORY" }, info[:type_of_contact])
    assert_equal({ ien: "55", name: "EXAMPLE HEALTH CENTER" }, info[:encounter_location])
    assert_equal({ ien: "9", name: "ON RESERVATION" }, info[:community_of_service])
    assert_equal({ ien: "12", name: "GROUP THERAPY" }, info[:activity])
  end

  # AMHGDGP.m:20 NEW's AMHPRGS; nothing ever assigns it. :28 emits the
  # external AMHPRG. GroupName is GET1^DIQ(...,.03,"I") at :24 — not a pair.
  def test_program_and_group_name_are_not_pairs
    seed_group_info

    info = G.group_information(7701)

    assert_equal "ADULT OUTPATIENT", info[:program], "external only — AMHPRGS is never assigned"
    assert_equal "ADULT SKILLS GROUP", info[:group_name]
  end

  # AMHGDGP.m:38 extracts the time fraction, :39-42 (commented) would pad it,
  # :43 assigns AMHARR="" unconditionally. Dead column; nil, not "".
  def test_arrival_time_is_always_nil_because_the_wire_blanks_it
    seed_group_info(arrival: "")

    assert_nil G.group_information(7701)[:arrival_time]
  end

  # ENC formats the encounter date through $$VCDT^AMHGU (AMHGDGP.m:23) —
  # "YR,MO,DY,HR,MN" — while GROUPL emits $$LVDT (AMHGDA.m:137). Same field,
  # two formats; we surface what arrives.
  def test_encounter_date_is_vcdt_not_lvdt
    seed_group_info

    assert_equal "2025,01,14,12,0", G.group_information(7701)[:encounter_date]
  end

  # AMHGDGP.m:45-47 — an inactive location clears AMHELOCI, which blanks the
  # entire pair (the external name is computed and then discarded).
  def test_inactive_location_or_community_arrives_as_a_blank_pair
    seed_group_info(location: "", community: "")

    info = G.group_information(7701)

    assert_nil info[:encounter_location]
    assert_nil info[:community_of_service]
  end

  def test_group_information_sends_one_pipe_delimited_parameter
    seed_group_info
    G.group_information(7701)

    call = @mock.received_calls.find { |c| c[:rpc] == "AMHG GET GROUP INFORMATION" }
    assert_equal [ "7701" ], call[:params]
  end

  def test_group_information_returns_nil_when_the_ien_yields_no_row
    seed(:amhg_group_information, "9999", ENC_HEADER)

    assert_nil G.group_information(9999)
  end

  # -- AMHG GET GROUP PATIENTS (PAT^AMHGDGP) ---------------------------------

  # AMHGDGP.m:206 — BMXIEN is the GROUP ien repeated; PatientIEN is the DFN;
  # AMHREC is $$GETREC^AMHGU (the linked visit). AMHDA is never emitted.
  def test_group_patients_repeat_the_group_ien_and_expose_dfn_and_visit
    seed(:amhg_group_patients, "7701", PAT_HEADER,
         "7701^100^8801^PATIENT,EXAMPLE^M^34^JAN 15, 1991^12345^")

    patients = G.group_patients(7701)

    assert_equal 1, patients.length
    p = patients.first
    assert_equal "7701", p[:group_ien], "BMXIEN is the group IEN repeated (AMHGDGP.m:206)"
    assert_equal "100", p[:patient_ien]
    assert_equal "8801", p[:visit_ien]
    assert_equal "PATIENT,EXAMPLE", p[:name]
    assert_equal "M", p[:sex], "internal sex (AMHGDGP.m:200)"
    assert_equal "34", p[:age]
    assert_equal "JAN 15, 1991", p[:dob], "$$LVDT of file 2 .03 (AMHGDGP.m:206)"
    assert_equal "12345", p[:chart]
    assert_nil p[:date_of_death]
    refute p.key?(:ien), "the patient subfile IEN AMHDA is never emitted (AMHGDGP.m:206)"
  end

  def test_group_patients_sends_one_pipe_delimited_parameter
    seed(:amhg_group_patients, "7701", PAT_HEADER,
         "7701^100^8801^PATIENT,EXAMPLE^M^34^JAN 15, 1991^12345^")
    G.group_patients(7701)

    call = @mock.received_calls.find { |c| c[:rpc] == "AMHG GET GROUP PATIENTS" }
    assert_equal [ "7701" ], call[:params]
  end

  # -- AMHG GET GROUP CPT (CPT^AMHGDGP) --------------------------------------

  # AMHGDGP.m:131 — BMXIEN is AMHCPTI, a pointer to file 81, not the
  # subfile IEN AMHDA. Rows cannot address a specific CPT entry.
  def test_group_cpt_first_column_is_a_code_pointer_not_a_record_ien
    seed(:amhg_group_cpt, "7701", CPT_HEADER,
         "1088^99213^OFFICE OUTPATIENT VISIT^1^99^GT^100^59")

    cpts = G.group_cpt(7701)

    assert_equal 1, cpts.length
    c = cpts.first
    assert_equal "1088", c[:code_pointer]
    refute c.key?(:ien), "the CPT subfile IEN is never emitted (AMHGDGP.m:117)"
    assert_equal "99213", c[:code]
    assert_equal "OFFICE OUTPATIENT VISIT", c[:narrative]
    assert_equal "1", c[:quantity]
    assert_equal "99", c[:mod1_ien]
    assert_equal "GT", c[:mod1]
    assert_equal "100", c[:mod2_ien]
    assert_equal "59", c[:mod2]
  end

  def test_group_cpt_sends_the_ien_alone_when_dupe_and_date_are_omitted
    seed(:amhg_group_cpt, "7701", CPT_HEADER,
         "1088^99213^OFFICE OUTPATIENT VISIT^1^^^")
    G.group_cpt(7701)

    call = @mock.received_calls.find { |c| c[:rpc] == "AMHG GET GROUP CPT" }
    assert_equal [ "7701" ], call[:params]
  end

  # AMHGDGP.m:112-114 — optional pieces 2/3 are AMHDUPE and AMHDATE (defaults
  # to DT when empty). Packed into the one pipe-delimited actual.
  def test_group_cpt_packs_optional_dupe_and_date
    seed(:amhg_group_cpt, "7701|1|3250114", CPT_HEADER)
    G.group_cpt(7701, dupe: 1, date: "3250114")

    call = @mock.received_calls.find { |c| c[:rpc] == "AMHG GET GROUP CPT" }
    assert_equal [ "7701|1|3250114" ], call[:params]
  end

  # -- AMHG GET GROUP EDU (EDU^AMHGDGP) --------------------------------------

  # AMHGDGP.m:181 — BMXIEN is AMHDA, the education subfile IEN. This is the
  # one group-tab list whose first column is actually addressable.
  #
  # Provider is IEN-name joined with a HYPHEN (AMHGDGP.m:179), not R="~".
  def test_group_edu_exposes_the_subfile_ien_and_hyphen_provider
    seed(:amhg_group_edu, "7701", EDU_HEADER,
         "3^DIABETES EDUCATION^15^GOOD^Discussed meal planning^98960^ACTIVE^Reduce A1C^412-THERAPIST,EXAMPLE")

    rows = G.group_edu(7701)

    assert_equal 1, rows.length
    e = rows.first
    assert_equal "3", e[:ien], "AMHDA — the 71-multiple IEN (AMHGDGP.m:181)"
    assert_equal "DIABETES EDUCATION", e[:topic]
    assert_equal "15", e[:time_spent]
    assert_equal "GOOD", e[:level_of_understanding]
    assert_equal "Discussed meal planning", e[:comment]
    assert_equal "98960", e[:cpt]
    assert_equal "ACTIVE", e[:status]
    assert_equal "Reduce A1C", e[:goal]
    assert_equal({ ien: "412", name: "THERAPIST,EXAMPLE" }, e[:provider])
  end

  def test_group_edu_blank_provider_is_nil
    seed(:amhg_group_edu, "7701", EDU_HEADER,
         "3^DIABETES EDUCATION^15^GOOD^Discussed meal planning^98960^ACTIVE^Reduce A1C^")

    assert_nil G.group_edu(7701).first[:provider]
  end

  # -- AMHG GET GROUP POV (POV^AMHGDGP) --------------------------------------

  # AMHGDGP.m:74, :81 — BMXIEN is AMHPOVI, +$G of the 21-multiple .01, a
  # pointer into 9002012.2. AMHDA is never emitted.
  def test_group_pov_first_column_is_a_code_pointer_not_a_record_ien
    seed(:amhg_group_pov, "7701", POV_HEADER,
         "441^F32.9^MAJOR DEPRESSIVE DISORDER, UNSPECIFIED",
         "512^F41.1^GENERALIZED ANXIETY DISORDER")

    povs = G.group_pov(7701)

    assert_equal 2, povs.length
    assert_equal "441", povs.first[:code_pointer]
    refute povs.first.key?(:ien), "the POV subfile IEN is never emitted (AMHGDGP.m:72)"
    assert_equal "F32.9", povs.first[:code]
    assert_equal "MAJOR DEPRESSIVE DISORDER, UNSPECIFIED", povs.first[:narrative]
  end

  def test_group_pov_packs_optional_dupe_and_date
    seed(:amhg_group_pov, "7701|1|3250114", POV_HEADER)
    G.group_pov(7701, dupe: 1, date: "3250114")

    call = @mock.received_calls.find { |c| c[:rpc] == "AMHG GET GROUP POV" }
    assert_equal [ "7701|1|3250114" ], call[:params]
  end

  # -- AMHG GET GROUP SOAP (SOAP^AMHGDGP) ------------------------------------

  # AMHGDGP.m:97 sends the raw node with NO caret sanitisation. Read as
  # whole lines — caret-splitting would invent columns.
  def test_group_soap_returns_raw_lines_keeping_carets
    seed(:amhg_group_soap, "7701", SOAP_HEADER,
         "S: Group discussed coping skills.",
         "O: Affect brighter ^ members engaged.")

    assert_equal [ "S: Group discussed coping skills.",
                   "O: Affect brighter ^ members engaged." ],
                 G.group_soap(7701)
  end

  def test_group_soap_is_empty_when_there_are_no_lines
    seed(:amhg_group_soap, "7701", SOAP_HEADER)

    assert_empty G.group_soap(7701)
  end

  # -- AMHG GET GROUP SEC PROVIDERS (SP^AMHGDGP) -----------------------------

  # AMHGDGP.m:151 — BMXIEN is AMHSPRVI, a pointer to file 200. The 11-multiple
  # IEN AMHDA is never emitted. Primary providers are filtered out (:147).
  def test_group_secondary_providers_first_column_is_the_provider_ien
    seed(:amhg_group_secondary_providers, "7701", SP_HEADER,
         "509^SUPERVISOR,EXAMPLE")

    providers = G.group_secondary_providers(7701)

    assert_equal 1, providers.length
    p = providers.first
    assert_equal "509", p[:provider_ien]
    assert_equal "SUPERVISOR,EXAMPLE", p[:name]
    refute p.key?(:ien), "the provider subfile IEN is never emitted (AMHGDGP.m:145)"
  end

  def test_group_secondary_providers_sends_one_pipe_delimited_parameter
    seed(:amhg_group_secondary_providers, "7701", SP_HEADER,
         "509^SUPERVISOR,EXAMPLE")
    G.group_secondary_providers(7701)

    call = @mock.received_calls.find { |c| c[:rpc] == "AMHG GET GROUP SEC PROVIDERS" }
    assert_equal [ "7701" ], call[:params]
  end
end
