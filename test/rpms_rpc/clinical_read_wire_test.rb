# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/allergy"

# Regression tests for issue #218: the four clinical reads feeding FHIR
# resources (Condition / Observation / MedicationRequest / AllergyIntolerance).
# Patient.find's unknown-DFN guard (finding 5) is a live spec now
# (test/live/patient_live_test.rb). Every fixture below is derived from the M routine's
# actual write statement (routine:line cited per test).
class ClinicalReadWireTest < Minitest::Test
  # Canned-response broker: returns one fixed response for every RPC.
  class RawResponseClient
    def initialize(response) = @response = response
    def call_rpc(*) = @response
  end

  def teardown
    RpmsRpc.reset!
  end

  def stub_broker_response(response)
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = RawResponseClient.new(response) }
  end

  # -- ORQQPL LIST (finding 1) ---------------------------------------------
  # LIST^ORQQPL reorders LIST^GMPLUTL2 rows (ORQQPL.m:14); the underlying row
  # is IFN^ST^NARR^ICD^ONSET^LASTMOD^SC^SP (GMPLUTL3.m:120), so the wire is
  # IEN^NARRATIVE^STATUS^ICD^ONSET^LASTMOD^SC^SPEXP.

  def test_problem_list_row_matches_orqqpl_wire_order
    row = RpmsRpc::DataMapper[:problem_list].parse_many(
      [ "123^Type 2 diabetes mellitus^A^E11.9^3200101^3250301.1015^NSC^^^^^1" ]
    ).first

    assert_equal "123", row[:ien]
    assert_equal "Type 2 diabetes mellitus", row[:description],
      "piece 2 is the provider narrative (GMPLUTL3.m:114,120)"
    assert_equal "A", row[:status],
      "piece 3 is the status code (GMPLUTL3.m:110,120)"
    assert_equal "E11.9", row[:icd_code]
    assert_equal Date.new(2020, 1, 1), row[:onset_date]
    assert_equal Date.new(2025, 3, 1), row[:last_modified],
      "piece 6 is date-last-modified (GMPLUTL3.m:109,120), not a recorded date"
    assert_equal "NSC", row[:service_connected],
      "piece 7 is SC/NSC (GMPLUTL3.m:111,120), not a provider DUZ"
  end

  def test_problem_list_no_problems_sentinel_yields_no_rows
    # ORQQPL.m:17: S:+$G(ORPY(1))<1 ORPY(1)="^No problems found."
    assert_equal [], RpmsRpc::DataMapper[:problem_list].parse_many([ "^No problems found." ])
  end

  def test_problem_list_unavailable_sentinel_yields_no_rows
    # ORQQPL.m:18: "^Problem list not available.^"
    assert_equal [], RpmsRpc::DataMapper[:problem_list].parse_many([ "^Problem list not available.^" ])
  end

  # -- ORQQVI VITALS FOR DATE RANGE (finding 2) ----------------------------
  # VITALS^ORQQVI row: "vital measurement ien^vital type^date/time taken^rate"
  # (ORQQVI.m:6, written at ORQQVI.m:23). This tag serves the registered
  # "ORQQVI VITALS FOR DATE RANGE" RPC (#8994 dump line 795), NOT
  # "ORQQVI VITALS", which dispatches to FASTVIT^ORQQVI (dump line 565) and
  # emits ien^type^rate^datetime — see :vitals in mappings_test.rb. These
  # assertions keep testing the ORQQVI.m:23 shape, now against the mapping
  # that actually carries it.

  def test_vitals_row_matches_orqqvi_wire_order
    row = RpmsRpc::DataMapper[:vitals_for_date_range]
          .parse_many([ "8001^BP^3260401.0815^120/80" ]).first

    assert_equal 8001, row[:measurement_ien], "piece 1 is the measurement IEN (ORQQVI.m:23)"
    assert_equal "BP", row[:type], "piece 2 is the vital type abbreviation (ORQQVI.m:23)"
    assert_equal Time.new(2026, 4, 1, 8, 15), row[:recorded_date],
      "piece 3 is the date/time taken (ORQQVI.m:23)"
    assert_equal "120/80", row[:value], "piece 4 is the rate (ORQQVI.m:23)"
  end

  def test_vitals_no_vitals_sentinel_yields_no_rows
    # ORQQVI.m:24: I I=0 S ORY(1)="^No vitals found."
    assert_equal [], RpmsRpc::DataMapper[:vitals_for_date_range].parse_many([ "^No vitals found." ])
  end

  # -- ORQQPS LIST (finding 3) ---------------------------------------------
  # LIST^ORQQPS row: "id^nameform^stop date^route^schedule/infusion rate^
  # refills remaining" (ORQQPS.m:5; outpatient row built at ORQQPS.m:47).

  def test_medication_list_row_matches_orqqps_wire_order
    row = RpmsRpc::DataMapper[:medication_list].parse_many(
      [ "5100;O^LISINOPRIL 10MG TAB^3270115^PO^QD^2" ]
    ).first

    assert_equal "5100;O", row[:id]   # piece 1 is the pharmacy order id ("403R;O"), not a file-50 IEN
    assert_equal "LISINOPRIL 10MG TAB", row[:name]
    assert_equal Date.new(2027, 1, 15), row[:stop_date],
      "piece 3 is the stop date (ORQQPS.m:5), not a sig"
    assert_equal "PO", row[:route], "piece 4 is the med route (ORQQPS.m:13-16,47)"
    assert_equal "QD", row[:schedule], "piece 5 is the schedule (ORQQPS.m:17-20,47)"
    assert_equal 2, row[:refills], "piece 6 is refills remaining (ORQQPS.m:47)"
  end

  def test_medication_list_no_medications_sentinel_yields_no_rows
    # ORQQPS.m:53: S:+$G(ORY(1))<1 ORY(1)="^No medications found."
    assert_equal [], RpmsRpc::DataMapper[:medication_list].parse_many([ "^No medications found." ])
  end

  # -- ORQQAL LIST (finding 4) ---------------------------------------------
  # LIST^ORQQAL row: allergy ien^agent^severity^signs (ORQQAL.m:14 emits
  # $P(GMRARXN(J),U,3)^$P(J,U)^$P(J,U,2) over EN1^GMRAOR1 rows of
  # agent^severity^ien; SIGNS appends ";"-joined signs — ORQQAL.m:18-21).

  def test_allergy_list_row_matches_orqqal_wire_order
    row = RpmsRpc::DataMapper[:allergy_list].parse_many(
      [ "667^PENICILLIN^SEVERE^HIVES;ANAPHYLAXIS" ]
    ).first

    assert_equal "667", row[:ien], "piece 1 is the allergy IEN (ORQQAL.m:14)"
    assert_equal "PENICILLIN", row[:allergen], "piece 2 is the causative agent (ORQQAL.m:14)"
    assert_equal "SEVERE", row[:severity], "piece 3 is the severity (GMRAOR1.m EN1)"
    assert_equal "HIVES;ANAPHYLAXIS", row[:signs],
      "piece 4 is the \";\"-joined signs/symptoms (ORQQAL.m:18-21)"
  end

  def test_allergy_sentinels_never_parse_as_allergy_records
    # ORQQAL.m:12-13,15 — assessment-state markers, not allergies.
    [ "^No Allergy Assessment", "^No Known Allergies", "^No allergies found." ].each do |sentinel|
      assert_equal [], RpmsRpc::DataMapper[:allergy_list].parse_many([ sentinel ]),
        "#{sentinel.inspect} must not surface as an allergy record"
    end
  end

  # -- Allergy.assessment three-state contract ------------------------------

  def test_allergy_assessment_not_assessed
    stub_broker_response([ "^No Allergy Assessment" ])

    result = RpmsRpc::Allergy.assessment("42")
    assert_equal({ assessed: false, nka: false, allergies: [] }, result)
  end

  def test_allergy_assessment_no_known_allergies
    stub_broker_response([ "^No Known Allergies" ])

    result = RpmsRpc::Allergy.assessment("42")
    assert_equal({ assessed: true, nka: true, allergies: [] }, result)
  end

  def test_allergy_assessment_with_allergies
    stub_broker_response([ "667^PENICILLIN^SEVERE^HIVES" ])

    result = RpmsRpc::Allergy.assessment("42")
    assert result[:assessed]
    refute result[:nka]
    assert_equal 1, result[:allergies].length
    assert_equal "PENICILLIN", result[:allergies].first[:allergen]
  end

  def test_allergy_for_patient_returns_no_records_for_nka_patient
    stub_broker_response([ "^No Known Allergies" ])

    assert_equal [], RpmsRpc::Allergy.for_patient("42"),
      "an NKA patient must not appear to HAVE an allergy named 'No Known Allergies'"
  end

  def test_parse_many_skips_error_rows_inside_arrays
    lines = [ "-1^No data found.", "667^PENICILLIN^SEVERE^HIVES" ]
    rows = RpmsRpc::DataMapper[:allergy_list].parse_many(lines)
    assert_equal 1, rows.length
    assert_equal "PENICILLIN", rows.first[:allergen]
  end

  # -- Allergy.assessment: a sentinel is only meaningful as the SOLE data line --
  # LIST^ORQQAL (ORQQAL.m:7-16, pinned build bcer-9.0-ydb and the FOIA copy)
  # sets GMRARXN to "", 0 or 1 — three mutually exclusive branches. The
  # "^No Allergy Assessment" and "^No Known Allergies" markers are written to
  # ORAY(1) only in the first two branches, and allergy rows only in the third,
  # so a real reply is EITHER one sentinel line OR rows. A reply that mixes a
  # sentinel with other data cannot come from ORQQAL itself: it is a corrupted
  # or concatenated reply, and must never read as verified absence (absence of
  # data is never verification). The allergies in it are real data and stay.

  PENICILLIN_ROW = "667^PENICILLIN^SEVERE^HIVES"

  def test_nka_sentinel_plus_a_real_row_is_not_verified_absence
    stub_broker_response([ "^No Known Allergies", PENICILLIN_ROW ])

    result = RpmsRpc::Allergy.assessment("42")
    refute result[:nka], "a reply that also carries an allergy row must not read as no-known-allergies"
    refute result[:assessed], "a contradictory reply is never presented as an assessed, complete record"
    assert_equal [ "PENICILLIN" ], result[:allergies].map { |a| a[:allergen] },
      "the rows stay available: hiding a possible allergy is the other unsafe direction"
    assert_equal true, result[:conflict], "the contradictory reply is flagged"
  end

  def test_nka_sentinel_after_a_real_row_is_not_verified_absence
    stub_broker_response([ PENICILLIN_ROW, "^No Known Allergies" ])

    result = RpmsRpc::Allergy.assessment("42")
    refute result[:nka]
    refute result[:assessed]
    assert_equal [ "PENICILLIN" ], result[:allergies].map { |a| a[:allergen] }
    assert_equal true, result[:conflict]
  end

  def test_not_assessed_sentinel_plus_a_real_row_keeps_the_row
    stub_broker_response([ "^No Allergy Assessment", PENICILLIN_ROW ])

    result = RpmsRpc::Allergy.assessment("42")
    refute result[:nka]
    refute result[:assessed], "the rows are returned, but never as an assessed record"
    assert_equal [ "PENICILLIN" ], result[:allergies].map { |a| a[:allergen] },
      "a real allergy must not be dropped because a not-assessed marker rode along"
    assert_equal true, result[:conflict]
  end

  def test_two_nka_sentinels_are_not_verified_absence
    stub_broker_response([ "^No Known Allergies", "^No Known Allergies" ])

    result = RpmsRpc::Allergy.assessment("42")
    refute result[:nka], "ORQQAL writes the marker once; a repeated marker is a corrupted reply"
    refute result[:assessed]
    assert_equal [], result[:allergies]
    assert_equal true, result[:conflict]
  end

  def test_nka_and_not_assessed_together_are_not_verified_absence
    stub_broker_response([ "^No Known Allergies", "^No Allergy Assessment" ])

    result = RpmsRpc::Allergy.assessment("42")
    refute result[:nka]
    refute result[:assessed]
    assert_equal [], result[:allergies]
    assert_equal true, result[:conflict]
  end

  # A mixed reply is the signature of a broker desync or a concatenated reply,
  # so its rows may belong to another call (or patient) or the list may be
  # truncated. They are still returned — hiding a possible allergy is the other
  # unsafe direction — but a conflicting reply is NEVER nka and NEVER assessed.
  CONFLICTING_REPLIES = {
    "NKA then a row" => [ "^No Known Allergies", PENICILLIN_ROW ],
    "a row then NKA" => [ PENICILLIN_ROW, "^No Known Allergies" ],
    "not-assessed then a row" => [ "^No Allergy Assessment", PENICILLIN_ROW ],
    "a row then not-assessed" => [ PENICILLIN_ROW, "^No Allergy Assessment" ],
    "NKA, a row, NKA" => [ "^No Known Allergies", PENICILLIN_ROW, "^No Known Allergies" ],
    "NKA twice" => [ "^No Known Allergies", "^No Known Allergies" ],
    "not-assessed twice" => [ "^No Allergy Assessment", "^No Allergy Assessment" ],
    "NKA and not-assessed" => [ "^No Known Allergies", "^No Allergy Assessment" ],
    "NKA, blank line, a row" => [ "^No Known Allergies", "", PENICILLIN_ROW ]
  }.freeze

  def test_a_conflicting_reply_is_never_nka_and_never_assessed
    CONFLICTING_REPLIES.each do |name, lines|
      stub_broker_response(lines)
      result = RpmsRpc::Allergy.assessment("42")

      refute result[:nka], "#{name}: a conflicting reply must never read as no-known-allergies"
      refute result[:assessed], "#{name}: a conflicting reply must never be presented as assessed, even with rows"
      assert_equal true, result[:conflict], "#{name}: the conflict is flagged"
    end
  end

  def test_a_conflicting_reply_keeps_every_real_row_available
    CONFLICTING_REPLIES.each do |name, lines|
      stub_broker_response(lines)
      expected = lines.count(PENICILLIN_ROW)

      assert_equal expected, RpmsRpc::Allergy.assessment("42")[:allergies].length,
        "#{name}: rows are returned (not hidden) even though the reply is not vouched for"
    end
  end

  def test_a_repeated_marker_with_no_rows_is_not_assessed
    [ [ "^No Known Allergies", "^No Known Allergies" ], [ "^No Allergy Assessment", "^No Allergy Assessment" ] ].each do |lines|
      stub_broker_response(lines)

      assert_equal({ assessed: false, nka: false, allergies: [], conflict: true },
        RpmsRpc::Allergy.assessment("42"), "#{lines.inspect}: no evidence means not assessed")
    end
  end

  def test_for_patient_returns_the_rows_of_a_mixed_reply
    stub_broker_response([ "^No Known Allergies", PENICILLIN_ROW ])

    assert_equal [ "PENICILLIN" ], RpmsRpc::Allergy.for_patient("42").map { |a| a[:allergen] }
  end

  # Guards: these already hold and must keep holding.

  def test_nka_sentinel_with_blank_lines_around_it_is_still_verified_absence
    stub_broker_response([ "^No Known Allergies", "", "  " ])

    assert_equal({ assessed: true, nka: true, allergies: [] }, RpmsRpc::Allergy.assessment("42"),
      "blank trailer lines are not data; a clean NKA reply carries no conflict key")
  end

  def test_clean_replies_carry_no_conflict_key
    [ [ "^No Known Allergies" ], [ "^No Allergy Assessment" ], [ PENICILLIN_ROW ] ].each do |lines|
      stub_broker_response(lines)
      refute_includes RpmsRpc::Allergy.assessment("42").keys, :conflict, "#{lines.inspect} is not contradictory"
    end
  end

  def test_garbled_sentinels_are_never_verified_absence
    [ [ "^No Known Allergies " ], [ "^no known allergies" ], [ "-1^error" ], [ "^No allergies found." ], [] ].each do |lines|
      stub_broker_response(lines)
      result = RpmsRpc::Allergy.assessment("42")

      refute result[:nka], "#{lines.inspect} must not read as verified absence"
      refute result[:assessed], "#{lines.inspect} is no evidence, so it is not assessed"
      assert_equal [], result[:allergies], "#{lines.inspect} must not surface a row"
    end
  end

  # -- The third marker, near-miss markers and phantom rows (panel round on #483) --
  # ORQQAL.m:15 writes a THIRD marker, "^No allergies found.", only when no
  # row was written — exactly as exclusive with rows as the other two. And a
  # marker that arrives slightly mangled (whitespace, a carriage return, a
  # no-break space, a zero-width character, a different case, an extra field)
  # is still a marker: beside data it makes the reply conflicting; alone it is
  # never verified absence. Verified absence stays strictly byte-exact.

  NEAR_MISS_MARKERS = {
    "trailing space" => "^No Known Allergies ",
    "carriage return" => "^No Known Allergies\r",
    "no-break space" => "^No Known Allergies\u00A0",
    "tab" => "^No Known Allergies\t",
    "upper case" => "^NO KNOWN ALLERGIES",
    "lower case" => "^no known allergies",
    "extra field" => "^No Known Allergies^extra",
    "extra empty field" => "^No Known Allergies^",
    "trailing zero-width space" => "^No Known Allergies\u200B",
    "trailing zero-width joiner" => "^No Known Allergies\u200D",
    "trailing byte-order mark" => "^No Known Allergies\uFEFF",
    "trailing word joiner" => "^No Known Allergies\u2060",
    "trailing soft hyphen" => "^No Known Allergies\u00AD",
    "trailing mongolian vowel separator" => "^No Known Allergies\u180E",
    "trailing combining grapheme joiner" => "^No Known Allergies\u034F",
    "word joiner in place of the space" => "^No Known\u2060Allergies",
    "soft hyphen in place of the space" => "^No Known\u00ADAllergies",
    "zero-width space in place of the space" => "^No Known\u200BAllergies",
    "zero-width space beside the space" => "^No Known \u200BAllergies",
    "no-break space in place of the space" => "^No Known\u00A0Allergies",
    "leading space" => " ^No Known Allergies",
    "leading no-break space" => "\u00A0^No Known Allergies",
    "not-assessed with trailing space" => "^No Allergy Assessment ",
    "third marker with trailing space" => "^No allergies found. "
  }.freeze

  # One test per entry, so a regression that breaks the Nth entry is not hidden
  # by an earlier failure in a loop.
  NEAR_MISS_MARKERS.each do |name, marker|
    slug = name.gsub(/\W+/, "_")

    define_method("test_near_miss_marker_beside_a_row_is_a_conflict_#{slug}") do
      [ [ marker, PENICILLIN_ROW ], [ PENICILLIN_ROW, marker ] ].each do |lines|
        stub_broker_response(lines)
        result = RpmsRpc::Allergy.assessment("42")

        refute result[:nka], "#{name}: never NKA beside data"
        refute result[:assessed], "#{name}: a conflicting reply is never assessed"
        assert_equal true, result[:conflict], "#{name}: the near-miss marker counts for conflict detection"
        assert_equal [ "PENICILLIN" ], result[:allergies].map { |a| a[:allergen] },
          "#{name}: the real row is kept and the marker makes no row of its own"
      end
    end

    define_method("test_near_miss_marker_alone_is_never_nka_and_never_a_row_#{slug}") do
      stub_broker_response([ marker ])

      assert_equal({ assessed: false, nka: false, allergies: [] }, RpmsRpc::Allergy.assessment("42"),
        "#{name}: only the byte-exact NKA marker as the sole data line is verified absence")
    end
  end

  def test_the_third_marker_alone_is_not_assessed_and_never_nka
    stub_broker_response([ "^No allergies found." ])

    assert_equal({ assessed: false, nka: false, allergies: [] }, RpmsRpc::Allergy.assessment("42"))
  end

  def test_the_third_marker_beside_a_row_is_a_conflict
    [ [ "^No allergies found.", PENICILLIN_ROW ], [ PENICILLIN_ROW, "^No allergies found." ] ].each do |lines|
      stub_broker_response(lines)
      result = RpmsRpc::Allergy.assessment("42")

      refute result[:nka]
      refute result[:assessed], "#{lines.inspect}: ORQQAL.m:15 writes this marker only when no row was written"
      assert_equal true, result[:conflict]
      assert_equal [ "PENICILLIN" ], result[:allergies].map { |a| a[:allergen] }
    end
  end

  def test_the_third_marker_beside_another_marker_is_a_conflict_without_rows
    [ "^No Known Allergies", "^No Allergy Assessment", "^No allergies found." ].each do |other|
      stub_broker_response([ "^No allergies found.", other ])

      assert_equal({ assessed: false, nka: false, allergies: [], conflict: true }, RpmsRpc::Allergy.assessment("42"),
        "the third marker with #{other.inspect}")
    end
  end

  def test_the_exact_nka_marker_stays_verified_absence_when_it_arrives_as_a_string_with_line_endings
    [ "^No Known Allergies\r\n", "^No Known Allergies\n", "^No Known Allergies" ].each do |response|
      stub_broker_response(response)

      assert_equal({ assessed: true, nka: true, allergies: [] }, RpmsRpc::Allergy.assessment("42"),
        "#{response.inspect}: line endings are not part of the marker")
    end
  end

  def test_a_reply_with_no_non_blank_line_is_not_assessed_and_has_no_rows
    [ [ "" ], [ "", "  " ], [ "  ", "\t" ], [ "\u00A0" ], [ "\u200B" ], [ "\r" ], [ "", "  ", "\t" ] ].each do |lines|
      stub_broker_response(lines)

      assert_equal({ assessed: false, nka: false, allergies: [] }, RpmsRpc::Allergy.assessment("42"),
        "#{lines.inspect}: whitespace is not data and must not become a row")
    end
  end

  def test_a_whitespace_line_beside_a_real_row_is_not_a_row
    stub_broker_response([ "  ", PENICILLIN_ROW, "\t" ])
    result = RpmsRpc::Allergy.assessment("42")

    assert result[:assessed]
    assert_equal [ "PENICILLIN" ], result[:allergies].map { |a| a[:allergen] }
    refute_includes result.keys, :conflict, "blank lines are not data and do not make a conflict"
  end

  def test_a_response_that_is_neither_text_nor_lines_is_unrecognised_not_assessed_and_has_no_rows
    [ { a: 1 }, 0, 42, :symbol, true ].each do |response|
      stub_broker_response(response)

      assert_equal({ assessed: false, nka: false, allergies: [], conflict: true }, RpmsRpc::Allergy.assessment("42"),
        "#{response.inspect}: no evidence, flagged as not a clean reply, and no row with a stringified ien")
    end
  end

  # -- Anything ORQQAL cannot emit is unrecognised, and is flagged (panel round 2 on #483) --
  # ORQQAL can emit exactly three markers, and every real row begins with the
  # allergy IEN, a positive integer (ORQQAL.m:13 writes $P(GMRARXN(J),"^",3) =
  # GMRAIEN first; GMRAOR1.m EN1 loops "Q:GMRAIEN<1"). So each line is one of:
  # a recognised marker, a valid row, blank, or UNRECOGNISED. A reply with any
  # unrecognised line, or a marker beside any other data, is a conflict: not
  # assessed, not NKA, and any allergen text it carries is returned (flagged,
  # never hidden). This closes the character lists for good: an unknown
  # lookalike can only make the answer louder, never safer-looking.

  LINE_BREAKS = {
    "line feed" => "\n", "carriage return" => "\r", "carriage return + line feed" => "\r\n",
    "line separator" => " ", "paragraph separator" => " ", "next line" => "\u0085"
  }.freeze

  LINE_BREAKS.each do |name, br|
    slug = name.gsub(/\W+/, "_")

    define_method("test_a_marker_glued_to_a_row_inside_one_array_element_by_a_#{slug}_is_a_conflict") do
      stub_broker_response([ "^No Known Allergies#{br}#{PENICILLIN_ROW}" ])
      result = RpmsRpc::Allergy.assessment("42")

      refute result[:nka]
      refute result[:assessed]
      assert_equal true, result[:conflict]
      assert_equal [ "PENICILLIN" ], result[:allergies].map { |a| a[:allergen] },
        "the glued reply is split into lines first, so the marker is not part of the row"
    end

    define_method("test_a_marker_glued_to_a_row_in_one_string_by_a_#{slug}_is_a_conflict") do
      stub_broker_response("^No Known Allergies#{br}#{PENICILLIN_ROW}")
      result = RpmsRpc::Allergy.assessment("42")

      refute result[:nka]
      refute result[:assessed]
      assert_equal true, result[:conflict]
      assert_equal [ "PENICILLIN" ], result[:allergies].map { |a| a[:allergen] }
    end

    define_method("test_two_clean_rows_separated_by_a_#{slug}_stay_clean") do
      stub_broker_response("#{PENICILLIN_ROW}#{br}668^LATEX^MILD^")
      result = RpmsRpc::Allergy.assessment("42")

      assert result[:assessed]
      refute_includes result.keys, :conflict
      assert_equal %w[PENICILLIN LATEX], result[:allergies].map { |a| a[:allergen] }
    end
  end

  def test_a_mixed_crlf_and_lf_reply_with_a_marker_is_a_conflict
    stub_broker_response("#{PENICILLIN_ROW}\r\n^No Known Allergies\n")

    result = RpmsRpc::Allergy.assessment("42")
    refute result[:assessed]
    assert_equal true, result[:conflict]
    assert_equal [ "PENICILLIN" ], result[:allergies].map { |a| a[:allergen] }
  end

  def test_a_non_string_element_in_a_list_is_unrecognised_and_makes_no_row_of_its_own
    [ [ { a: 1 }, PENICILLIN_ROW ], [ 5, "^No Known Allergies" ], [ [ "^No Known Allergies" ] ],
      [ nil, PENICILLIN_ROW ], [ PENICILLIN_ROW, :sym ] ].each do |lines|
      stub_broker_response(lines)
      result = RpmsRpc::Allergy.assessment("42")

      refute result[:nka], "#{lines.inspect}"
      refute result[:assessed], "#{lines.inspect}: an element that is not text is not a clean reply"
      assert_equal true, result[:conflict], "#{lines.inspect}"
      assert_equal lines.include?(PENICILLIN_ROW) ? [ "PENICILLIN" ] : [], result[:allergies].map { |a| a[:allergen] },
        "#{lines.inspect}: no row is built from the stringified element"
    end
  end

  LOOKALIKE_MARKERS = {
    "fullwidth caret" => "＾No Known Allergies",
    "quoted" => "\"^No Known Allergies\"",
    "double caret" => "^^No Known Allergies",
    "trailing period" => "^No Known Allergies.",
    "third marker without its period" => "^No allergies found",
    "cyrillic o" => "^Nо Known Allergies",
    "fullwidth letters" => "^Ｎｏ Known Allergies",
    "bare zero" => "0",
    "marker text without the caret" => "No Known Allergies",
    "not-assessed with a typo" => "^No Allergy Assesment"
  }.freeze

  LOOKALIKE_MARKERS.each do |name, line|
    slug = name.gsub(/\W+/, "_")

    define_method("test_lookalike_marker_alone_is_not_assessed_not_nka_and_flagged_#{slug}") do
      stub_broker_response([ line ])
      result = RpmsRpc::Allergy.assessment("42")

      refute result[:nka]
      refute result[:assessed], "#{name}: an unrecognised line is no evidence"
      assert_equal true, result[:conflict], "#{name}: flagged as not a clean reply"
    end

    define_method("test_lookalike_marker_beside_a_row_is_a_conflict_#{slug}") do
      stub_broker_response([ line, PENICILLIN_ROW ])
      result = RpmsRpc::Allergy.assessment("42")

      refute result[:nka]
      refute result[:assessed]
      assert_equal true, result[:conflict]
      assert_includes result[:allergies].map { |a| a[:allergen] }, "PENICILLIN", "#{name}: the real row is never hidden"
    end
  end

  def test_a_lookalike_with_allergen_text_is_returned_flagged_not_dropped
    stub_broker_response([ "^No Known Allergies." ])

    result = RpmsRpc::Allergy.assessment("42")
    refute result[:assessed]
    assert_equal true, result[:conflict]
    assert_equal [ "No Known Allergies." ], result[:allergies].map { |a| a[:allergen] },
      "a possible allergy is flagged, not hidden"
  end

  def test_a_row_with_no_ien_but_an_allergen_is_returned_flagged_not_dropped
    stub_broker_response([ "^PENICILLIN^SEVERE^HIVES" ])

    result = RpmsRpc::Allergy.assessment("42")
    refute result[:nka]
    refute result[:assessed], "a row ORQQAL cannot emit (every real row starts with a positive allergy IEN) is not vouched for"
    assert_equal true, result[:conflict]
    assert_equal [ "PENICILLIN" ], result[:allergies].map { |a| a[:allergen] }
  end

  def test_a_row_with_a_non_numeric_or_zero_ien_is_unrecognised
    [ "0^PENICILLIN^SEVERE^HIVES", "-3^PENICILLIN^SEVERE^HIVES", "x1^PENICILLIN^SEVERE^HIVES", "1.5^PENICILLIN^SEVERE^HIVES" ].each do |row|
      stub_broker_response([ row ])
      result = RpmsRpc::Allergy.assessment("42")

      refute result[:assessed], "#{row.inspect}"
      assert_equal true, result[:conflict], "#{row.inspect}"
    end
  end

  def test_a_line_with_text_but_no_allergen_piece_is_flagged_and_makes_no_row
    [ "garbage", "just text", "T00030NAME^", "[" ].each do |line|
      stub_broker_response([ PENICILLIN_ROW, line ])
      result = RpmsRpc::Allergy.assessment("42")

      refute result[:assessed], "#{line.inspect}"
      assert_equal true, result[:conflict], "#{line.inspect}"
      assert_equal [ "PENICILLIN" ], result[:allergies].map { |a| a[:allergen] }, "#{line.inspect}"
    end
  end

  def test_an_allergen_whose_text_mentions_the_marker_is_a_normal_row
    [ "12^No Known Allergies to latex^MILD^", "12^No Known Allergies^^", "12^no allergies found for this drug^^" ].each do |row|
      stub_broker_response([ row ])
      result = RpmsRpc::Allergy.assessment("42")

      assert result[:assessed], "#{row.inspect} has a numeric ien, so it is a row"
      refute result[:nka]
      refute_includes result.keys, :conflict, "#{row.inspect}: no false conflict"
      assert_equal 1, result[:allergies].length
    end
  end

  def test_invisible_only_lines_are_blank_not_data
    [ "⁠", "­", "᠎", "͏", "​", "﻿", "‍", " ", "\t" ].each do |blank|
      stub_broker_response([ blank ])

      assert_equal({ assessed: false, nka: false, allergies: [] }, RpmsRpc::Allergy.assessment("42"),
        "#{blank.inspect} has nothing visible in it: no phantom row")
    end
  end

  # The encoding handling for matching: a marker tagged as another encoding, or
  # carrying a stray byte, must neither raise nor hide the conflict.

  def test_a_latin_1_tagged_no_break_space_after_a_marker_still_counts_as_a_marker
    marker = "^No Known Allergies\xA0".dup.force_encoding("ISO-8859-1")
    stub_broker_response([ marker, PENICILLIN_ROW ])

    result = RpmsRpc::Allergy.assessment("42")
    refute result[:assessed]
    assert_equal true, result[:conflict]
    assert_equal [ "PENICILLIN" ], result[:allergies].map { |a| a[:allergen] }
  end

  def test_a_binary_tagged_utf_8_no_break_space_after_a_marker_still_counts_as_a_marker
    stub_broker_response([ "^No Known Allergies ".b, PENICILLIN_ROW ])

    result = RpmsRpc::Allergy.assessment("42")
    refute result[:assessed]
    assert_equal true, result[:conflict]
    assert_equal [ "PENICILLIN" ], result[:allergies].map { |a| a[:allergen] }
  end

  def test_an_invalid_byte_line_beside_a_row_is_flagged_and_does_not_raise
    stub_broker_response([ PENICILLIN_ROW, "\xFF".dup.force_encoding("UTF-8") ])

    result = RpmsRpc::Allergy.assessment("42")
    refute result[:assessed]
    assert_equal true, result[:conflict]
    assert_equal [ "PENICILLIN" ], result[:allergies].map { |a| a[:allergen] }
  end

  def test_an_invalid_byte_line_alone_is_not_assessed_and_flagged
    stub_broker_response([ "\xFF\xFE".dup.force_encoding("UTF-8") ])

    result = RpmsRpc::Allergy.assessment("42")
    refute result[:nka]
    refute result[:assessed]
    assert_equal [], result[:allergies]
    assert_equal true, result[:conflict]
  end

  def test_a_row_with_an_invalid_byte_does_not_raise_and_stays_a_row
    stub_broker_response([ "667^PENICILLIN\xFF^SEVERE^HIVES".dup.force_encoding("UTF-8") ])

    result = RpmsRpc::Allergy.assessment("42")
    assert result[:assessed]
    assert_equal 1, result[:allergies].length
  end
end
