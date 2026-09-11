# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/behavioral_health/intake"

# Tests for RpmsRpc::BehavioralHealth::Intake — AMHG intake reads
# (INTAKEL^AMHGDA, INT^AMHGDINT). DELETE is held.
#
# Fixtures are hand-built from the M source, not round-tripped through our
# own formatter. Per ADR 0003 these are the first evidence. All data synthetic.
class BehavioralHealthIntakeTest < Minitest::Test
  I = RpmsRpc::BehavioralHealth::Intake
  RS = "\x1e"  # $C(30) record separator
  US = "\x1f"  # $C(31) end of recordset

  # INTAKEL^AMHGDA header, AMHGDA.m:148. Eight columns, eight row fields
  # (AMHGDA.m:167). No multi-SET append.
  INTAKE_HEADER =
    "T00010BMXIEN^T00030SortDate^T00030Date^T00050Program^T00050InitialProvider^" \
    "T00007VisitIEN^T00030Visit^T00050PrimaryProvider"

  # INT^AMHGDINT header is TWO SETs (AMHGDINT.m:22-23). A reader that stops
  # at the first loses T00010UserUpdate and T00030DateofLastUpdate — 15
  # columns, not the 13 a single-line read of :22 shows.
  DOCS_HEADER =
    "T00010BMXIEN^T00001Type^T00010AMHREC^T00030DateInitial^T00030Program^" \
    "T00030ProviderInitial^T00030DateUpdate^T00030ProviderUpdate^T00001Signed^" \
    "T00010IPIen^T00010UpdIen^T00010InitialIntake^T00030UpdateProgram^" \
    "T00010UserUpdate^T00030DateofLastUpdate"

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

  # -- AMHG GET INTAKE (INTAKEL^AMHGDA) --------------------------------------

  # Eight fields, matching the row built at AMHGDA.m:167. Program is the
  # VISIT's .02 (AMHGDA.m:161), not the intake's .05. InitialProvider is
  # intake .04 (AMHGDA.m:162); PrimaryProvider is $$GETPRV of the visit
  # (AMHGDA.m:164-165) — two different people are possible.
  def intake_row(ien: "5501",
                 initial_provider: "THERAPIST,EXAMPLE",
                 primary_provider: "COUNSELOR,EXAMPLE")
    [ ien, "3250114", "JAN 14, 2025", "ADULT OUTPATIENT", initial_provider,
      "8801", "JAN 14, 2025", primary_provider ].join("^")
  end

  def seed_intakes(*rows)
    seed(:amhg_intake_list, "3250101|3251231|100", INTAKE_HEADER, *rows)
  end

  def test_intakes_parses_the_eight_field_row_and_skips_the_header
    seed_intakes(intake_row)

    intakes = I.intakes(100, from: "3250101", to: "3251231")

    assert_equal 1, intakes.length, "header and $C(31) terminator are not records"
    row = intakes.first
    assert_equal "5501", row[:ien]
    assert_equal "3250114", row[:sort_date]
    assert_equal "JAN 14, 2025", row[:date]
    assert_equal "ADULT OUTPATIENT", row[:program]
    assert_equal "THERAPIST,EXAMPLE", row[:initial_provider]
    assert_equal "8801", row[:visit_ien]
    assert_equal "JAN 14, 2025", row[:visit_date]
    assert_equal "COUNSELOR,EXAMPLE", row[:primary_provider]
  end

  # AMHGDA.m:162 vs :164-165 — InitialProvider is the intake's .04;
  # PrimaryProvider is the visit's primary. The columns are not aliases.
  def test_intakes_initial_provider_and_primary_provider_are_distinct
    seed_intakes(intake_row(initial_provider: "THERAPIST,EXAMPLE",
                            primary_provider: "COUNSELOR,EXAMPLE"))

    row = I.intakes(100, from: "3250101", to: "3251231").first

    refute_equal row[:initial_provider], row[:primary_provider]
  end

  # AMHGDA.m:154 walks ^AMHRINTK("AE",AMHP,...) — AE's first subscript is
  # the patient, same pattern as VISITL's ^AMHREC("AE",AMHP) (AMHGD.m:24).
  # The third pipe piece is a DFN, not the PROVIDER IEN GROUPL uses.
  def test_intakes_sends_one_pipe_delimited_parameter_with_dfn_not_provider
    seed_intakes(intake_row)
    I.intakes(100, from: "3250101", to: "3251231")

    call = @mock.received_calls.find { |c| c[:rpc] == "AMHG GET INTAKE" }
    assert_equal 1, call[:params].length,
                 "AMH rejects multi-actual calls with YDB-E-ACTLSTTOOLONG (#198)"
    assert_equal "3250101|3251231|100", call[:params].first
  end

  def test_intakes_are_returned_in_wire_order
    seed_intakes(intake_row(ien: "5502"), intake_row(ien: "5501"))

    assert_equal %w[5502 5501], I.intakes(100, from: "3250101", to: "3251231").map { _1[:ien] }
  end

  def test_intakes_with_no_records_returns_empty
    seed_intakes

    assert_empty I.intakes(100, from: "3250101", to: "3251231")
  end

  # -- AMHG GET INTAKE DOCUMENTS (INT^AMHGDINT) ------------------------------

  # Fifteen fields, matching AMHGDINT.m:55 (initial) and :71 (update).
  # DateUpdate/ProviderUpdate/InitialIntake/UpdateProgram are blank on
  # initials (:55). DateInitial/Program/ProviderInitial are blank on
  # updates (:71).
  def initial_doc_row(ien: "5501", signed: "Y")
    [ ien, "I", "8801", "JAN 14, 2025", "ADULT OUTPATIENT", "THERAPIST,EXAMPLE",
      "", "", signed, "412", "99", "", "", "88", "3250114" ].join("^")
  end

  def update_doc_row(ien: "5502", signed: "N", parent: "5501")
    [ ien, "U", "8801", "", "", "", "FEB 20, 2025", "COUNSELOR,EXAMPLE",
      signed, "413", "100", parent, "ADULT OUTPATIENT", "88", "3250220" ].join("^")
  end

  def seed_docs(*rows)
    seed(:amhg_intake_documents, "100|ADULT OUTPATIENT|3250101|3251231", DOCS_HEADER, *rows)
  end

  def test_intake_documents_parses_all_fifteen_columns_not_the_thirteen_a_single_set_would_show
    seed_docs(initial_doc_row)

    docs = I.intake_documents(100, program: "ADULT OUTPATIENT", from: "3250101", to: "3251231")

    assert_equal 1, docs.length, "header and $C(31) terminator are not records"
    row = docs.first
    assert_equal "5501", row[:ien]
    assert_equal :initial, row[:type]
    assert_equal "8801", row[:visit_ien]
    assert_equal "JAN 14, 2025", row[:date_initial]
    assert_equal "ADULT OUTPATIENT", row[:program]
    assert_equal({ ien: "412", name: "THERAPIST,EXAMPLE" }, row[:provider])
    assert_nil row[:date_update]
    assert_equal true, row[:signed]
    assert_equal "99", row[:entered_by_ien]
    assert_nil row[:initial_intake_ien]
    assert_nil row[:update_program]
    assert_equal "88", row[:last_update_user_ien]
    assert_equal "3250114", row[:last_update_date],
                 "column 15 — only reachable if both header SETs are read (AMHGDINT.m:22-23)"
  end

  def test_intake_documents_update_row_fills_the_update_columns_and_blanks_the_initial_ones
    seed_docs(update_doc_row)

    row = I.intake_documents(100, program: "ADULT OUTPATIENT", from: "3250101", to: "3251231").first

    assert_equal "5502", row[:ien], "BMXIEN is the UPDATE ien (AMHY), not the parent (AMHGDINT.m:71)"
    assert_equal :update, row[:type]
    assert_nil row[:date_initial]
    assert_nil row[:program]
    assert_equal "FEB 20, 2025", row[:date_update]
    assert_equal({ ien: "413", name: "COUNSELOR,EXAMPLE" }, row[:provider])
    assert_equal false, row[:signed]
    assert_equal "5501", row[:initial_intake_ien]
    assert_equal "ADULT OUTPATIENT", row[:update_program]
    assert_equal "3250220", row[:last_update_date]
  end

  # AMHGDINT.m:52 — Signed is "Y"/"N" from field .11, not the inverted "*"
  # VISITL/GROUPL emit. flag?("N") would be true; the API must not use it.
  def test_intake_documents_signed_is_y_n_not_an_inverted_star
    seed_docs(initial_doc_row(signed: "Y"), update_doc_row(signed: "N"))

    signed, unsigned = I.intake_documents(100, program: "ADULT OUTPATIENT", from: "3250101", to: "3251231")

    assert signed[:signed], '"Y" means signed (AMHGDINT.m:52)'
    refute unsigned[:signed], '"N" means NOT signed — flag?("N") would lie'
  end

  # AMHGDINT.m:49 — UpdIen is field .13 "I" (the entering user), not an
  # update-record IEN. The update's own IEN is BMXIEN when Type is "U".
  def test_intake_documents_updien_is_the_entering_user_not_an_update_ien
    seed_docs(initial_doc_row)

    row = I.intake_documents(100, program: "ADULT OUTPATIENT", from: "3250101", to: "3251231").first

    assert_equal "99", row[:entered_by_ien]
    refute_equal row[:ien], row[:entered_by_ien]
  end

  # AMHGDINT.m:51 — DateofLastUpdate is GET1 of .07 "I" (internal FileMan).
  # DateInitial / DateUpdate are $$LVDT display. Same conceptual "date",
  # two formats; we surface what arrives.
  def test_intake_documents_last_update_date_is_internal_fileman_not_lvdt
    seed_docs(initial_doc_row)

    row = I.intake_documents(100, program: "ADULT OUTPATIENT", from: "3250101", to: "3251231").first

    assert_equal "3250114", row[:last_update_date]
    assert_equal "JAN 14, 2025", row[:date_initial]
  end

  # INT^AMHGDINT takes patient|program|begin|end (AMHGDINT.m:14-17) — a
  # patient DFN first, not an intake IEN. ASSESS^AMHGDINT (same routine)
  # is the one that takes an intake IEN despite being named GET VISIT
  # ASSESSMENT. This RPC's name matches its entity; its first actual does
  # not match ASSESS and does not match INTAKEL's begin|end|dfn order.
  def test_intake_documents_sends_patient_program_dates_not_an_intake_ien
    seed_docs(initial_doc_row)
    I.intake_documents(100, program: "ADULT OUTPATIENT", from: "3250101", to: "3251231")

    call = @mock.received_calls.find { |c| c[:rpc] == "AMHG GET INTAKE DOCUMENTS" }
    assert_equal 1, call[:params].length,
                 "AMH rejects multi-actual calls with YDB-E-ACTLSTTOOLONG (#198)"
    assert_equal "100|ADULT OUTPATIENT|3250101|3251231", call[:params].first
  end

  def test_intake_documents_with_no_records_returns_empty
    seed_docs

    assert_empty I.intake_documents(100, program: "ADULT OUTPATIENT", from: "3250101", to: "3251231")
  end
end
