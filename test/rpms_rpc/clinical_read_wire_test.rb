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
    stub_broker_response([ "^No Known Allergies", "", "" ])

    assert_equal({ assessed: true, nka: true, allergies: [] }, RpmsRpc::Allergy.assessment("42"),
      "empty trailer lines are not data; a clean NKA reply carries no conflict key")
  end

  def test_clean_replies_carry_no_conflict_key
    [ [ "^No Known Allergies" ], [ "^No Allergy Assessment" ], [ PENICILLIN_ROW ] ].each do |lines|
      stub_broker_response(lines)
      refute_includes RpmsRpc::Allergy.assessment("42").keys, :conflict, "#{lines.inspect} is not contradictory"
    end
  end

  def test_garbled_sentinels_are_never_verified_absence
    [ [ "^No Known Allergies " ], [ "^no known allergies" ], [ "^No allergies found." ], [] ].each do |lines|
      stub_broker_response(lines)
      result = RpmsRpc::Allergy.assessment("42")

      refute result[:nka], "#{lines.inspect} must not read as verified absence"
      refute result[:assessed], "#{lines.inspect} is no evidence, so it is not assessed"
      assert_equal [], result[:allergies], "#{lines.inspect} must not surface a row"
    end
  end

  # "-1^error" is not a marker. An error row could be "-3^PENICILLIN": its text
  # is surfaced, flagged, rather than filtered as a broker error.
  def test_an_error_shaped_row_is_never_verified_absence_and_is_surfaced_flagged
    stub_broker_response([ "-1^error" ])
    result = RpmsRpc::Allergy.assessment("42")

    refute result[:nka]
    refute result[:assessed]
    assert_equal true, result[:conflict]
    assert_equal [ "-1^error" ], result[:allergies].map { |a| a[:raw] }
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

  # Round 4: a line terminator that splitting a String reply produces is fine
  # ("marker\r\n" is the real shape), but a separate Array element is one line
  # already: if it still carries a terminator it is not byte-exact, so it is a
  # lone marker (not assessed, never NKA).
  def test_an_array_element_carrying_a_line_terminator_is_not_byte_exact_so_never_nka
    [ "\r", "\n", "\r\n", "\u2028", "\u2029", "\u0085" ].each do |terminator|
      [ "^No Known Allergies#{terminator}", "#{terminator}^No Known Allergies", "#{terminator}^No Known Allergies#{terminator}" ].each do |element|
        stub_broker_response([ element ])

        assert_equal({ assessed: false, nka: false, allergies: [] }, RpmsRpc::Allergy.assessment("42"),
          "#{element.inspect}: an Array element must be the byte-exact marker")
      end
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
    [ "^No Known Allergies\r\n", "^No Known Allergies\n", "^No Known Allergies", "\r^No Known Allergies",
      "\r\n^No Known Allergies\r\n", "^No Known Allergies\n\n" ].each do |response|
      stub_broker_response(response)

      assert_equal({ assessed: true, nka: true, allergies: [] }, RpmsRpc::Allergy.assessment("42"),
        "#{response.inspect}: line endings are not part of the marker")
    end
  end

  def test_a_reply_with_no_non_blank_line_is_not_assessed_and_has_no_rows
    [ [ "" ], [ "", "" ], [ "\r" ], [ "\r\n" ], [] ].each do |lines|
      stub_broker_response(lines)

      assert_equal({ assessed: false, nka: false, allergies: [] }, RpmsRpc::Allergy.assessment("42"),
        "#{lines.inspect}: only genuinely empty segments are ignorable")
    end
  end

  def test_a_whitespace_line_beside_a_real_row_is_unrecognised_not_a_row
    stub_broker_response([ "  ", PENICILLIN_ROW, "\t" ])
    result = RpmsRpc::Allergy.assessment("42")

    refute result[:assessed], "whitespace-only content is a shape ORQQAL cannot emit"
    assert_equal true, result[:conflict]
    assert_equal [ "  ", "PENICILLIN", "\t" ], result[:allergies].map { |a| a[:raw] || a[:allergen] }
    assert_equal [ true, nil, true ], result[:allergies].map { |a| a[:unrecognised] }
  end

  def test_a_response_that_is_neither_text_nor_lines_is_unrecognised_not_assessed_and_has_no_rows
    [ { a: 1 }, 0, 42, :symbol, true ].each do |response|
      stub_broker_response(response)

      assert_equal({ assessed: false, nka: false, conflict: true,
                     allergies: [ { ien: nil, allergen: response.inspect, raw: response.inspect, unrecognised: true } ] },
        RpmsRpc::Allergy.assessment("42"),
        "#{response.inspect}: flagged as not a clean reply, its inspect text surfaced, and no row with a stringified ien")
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
    [ [ { a: 1 }, PENICILLIN_ROW ], [ 5, "^No Known Allergies" ],
      [ nil, PENICILLIN_ROW ], [ PENICILLIN_ROW, :sym ] ].each do |lines|
      stub_broker_response(lines)
      result = RpmsRpc::Allergy.assessment("42")

      refute result[:nka], "#{lines.inspect}"
      refute result[:assessed], "#{lines.inspect}: an element that is not text is not a clean reply"
      assert_equal true, result[:conflict], "#{lines.inspect}"
      expected = lines.filter_map do |l|
        if l == PENICILLIN_ROW then "PENICILLIN"
        elsif l.is_a?(String) || l.nil? then nil # a marker makes no entry
        else l.inspect
        end
      end
      assert_equal expected, result[:allergies].map { |a| a[:allergen] },
        "#{lines.inspect}: the element's inspect text is surfaced, never a row built from it"
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
      assert_equal [ line ], result[:allergies].map { |a| a[:raw] }, "#{name}: its text is surfaced verbatim, never filtered"
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

  def test_a_no_data_message_lookalike_is_flagged_and_is_not_an_allergy
    # DataMapper would drop any "^message" row (empty first piece, text in
    # piece 2, nothing after it) as a no-data sentinel, but an unrecognised line
    # never goes through that filter: its text is surfaced verbatim, flagged.
    stub_broker_response([ "^No Known Allergies." ])

    result = RpmsRpc::Allergy.assessment("42")
    refute result[:nka]
    refute result[:assessed]
    assert_equal true, result[:conflict]
    assert_equal [ { ien: nil, allergen: "^No Known Allergies.", raw: "^No Known Allergies.", unrecognised: true } ],
      result[:allergies]
  end

  def test_an_unrecognised_row_that_carries_allergen_text_is_returned_flagged_not_dropped
    stub_broker_response([ "x1^LATEX^MILD^RASH" ])

    result = RpmsRpc::Allergy.assessment("42")
    refute result[:nka]
    refute result[:assessed]
    assert_equal true, result[:conflict]
    assert_equal [ "x1^LATEX^MILD^RASH" ], result[:allergies].map { |a| a[:raw] }, "a possible allergy is flagged, not hidden"
    assert_equal [ true ], result[:allergies].map { |a| a[:unrecognised] }
  end

  def test_a_row_with_no_ien_but_an_allergen_is_returned_flagged_not_dropped
    stub_broker_response([ "^PENICILLIN^SEVERE^HIVES" ])

    result = RpmsRpc::Allergy.assessment("42")
    refute result[:nka]
    refute result[:assessed], "a row ORQQAL cannot emit (every real row starts with a positive allergy IEN) is not vouched for"
    assert_equal true, result[:conflict]
    assert_equal [ "^PENICILLIN^SEVERE^HIVES" ], result[:allergies].map { |a| a[:raw] }
  end

  def test_a_row_with_a_non_numeric_or_zero_ien_is_unrecognised_and_its_text_is_surfaced
    [ "0^PENICILLIN^SEVERE^HIVES", "-3^PENICILLIN^SEVERE^HIVES", "x1^PENICILLIN^SEVERE^HIVES", "1.5^PENICILLIN^SEVERE^HIVES",
      "-5^LATEX^SEVERE", "^LATEX", "^LATEX^" ].each do |row|
      stub_broker_response([ row ])
      result = RpmsRpc::Allergy.assessment("42")

      refute result[:assessed], "#{row.inspect}"
      refute result[:nka], "#{row.inspect}"
      assert_equal true, result[:conflict], "#{row.inspect}"
      assert_equal [ row ], result[:allergies].map { |a| a[:raw] }, "#{row.inspect}: the line is surfaced verbatim, never filtered as an error or no-data row"
      assert_equal [ row ], result[:allergies].map { |a| a[:allergen] }
    end
  end

  def test_a_line_with_text_but_no_allergen_piece_is_flagged_and_surfaced
    [ "garbage", "just text", "T00030NAME^", "[" ].each do |line|
      stub_broker_response([ PENICILLIN_ROW, line ])
      result = RpmsRpc::Allergy.assessment("42")

      refute result[:assessed], "#{line.inspect}"
      assert_equal true, result[:conflict], "#{line.inspect}"
      assert_equal [ "PENICILLIN", line ], result[:allergies].map { |a| a[:allergen] }, "#{line.inspect}: the text is surfaced, flagged"
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

  def test_whitespace_or_invisible_only_lines_are_unrecognised_not_a_row_and_not_blank
    [ "⁠", "­", "᠎", "͏", "​", "﻿", "‍", " ", "\t" ].each do |line|
      stub_broker_response([ line ])
      result = RpmsRpc::Allergy.assessment("42")

      refute result[:assessed], line.inspect
      refute result[:nka]
      assert_equal true, result[:conflict], line.inspect
      assert_equal [ line ], result[:allergies].map { |a| a[:raw] }, "#{line.inspect}: surfaced with its raw bytes, no phantom row"
      assert_equal [ true ], result[:allergies].map { |a| a[:unrecognised] }
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
    assert_equal [ "PENICILLIN", "\xFF".b ], result[:allergies].map { |a| (a[:raw] || a[:allergen]).b }
    assert_equal [ nil, true ], result[:allergies].map { |a| a[:unrecognised] }
  end

  def test_an_invalid_byte_line_alone_is_not_assessed_and_flagged
    stub_broker_response([ "\xFF\xFE".dup.force_encoding("UTF-8") ])

    result = RpmsRpc::Allergy.assessment("42")
    refute result[:nka]
    refute result[:assessed]
    assert_equal [ "\xFF\xFE".b ], result[:allergies].map { |a| a[:raw].b }, "surfaced with its raw bytes"
    assert_equal true, result[:conflict]
  end

  def test_a_conflicting_reply_with_an_invalid_byte_row_does_not_raise_and_keeps_the_row
    [ [ "^No Known Allergies", "667^PENICILLIN\xFF^SEVERE^HIVES" ], [ "x1^LATEX\xFF^MILD^RASH" ] ].each do |lines|
      stub_broker_response(lines.map { |line| line.dup.force_encoding("UTF-8") })
      result = RpmsRpc::Allergy.assessment("42")

      refute result[:nka], lines.inspect
      refute result[:assessed], lines.inspect
      assert_equal true, result[:conflict], lines.inspect
      assert_equal 1, result[:allergies].length, "#{lines.inspect}: the row is kept, not dropped, and nothing raises"
    end
  end

  def test_a_row_with_an_invalid_byte_does_not_raise_and_stays_a_row
    stub_broker_response([ "667^PENICILLIN\xFF^SEVERE^HIVES".dup.force_encoding("UTF-8") ])

    result = RpmsRpc::Allergy.assessment("42")
    assert result[:assessed]
    assert_equal 1, result[:allergies].length
  end

  # -- Panel round 3 on #483: never hide, never vouch ------------------------
  # Every UNRECOGNISED line that has any visible text is surfaced verbatim as a
  # flagged entry ({ ien: nil, allergen:, raw:, unrecognised: true }); it is
  # never routed through DataMapper's error/sentinel filters, which would drop it.

  def entry_for(line, **extra)
    { ien: nil, allergen: line.strip, raw: line, unrecognised: true }.merge(extra)
  end

  MARKER_WITH_EXTRA_PIECES = [
    "^No Known Allergies^LATEX^SEVERE", "^No Allergy Assessment^LATEX^SEVERE", "^No allergies found.^LATEX",
    "^No Known Allergies^extra", "^No Known Allergies^^LATEX", "^No Known Allergies ^ LATEX"
  ].freeze

  MARKER_WITH_EXTRA_PIECES.each_with_index do |line, i|
    define_method("test_marker_with_extra_non_blank_pieces_alone_is_unrecognised_and_its_text_is_surfaced_#{i}") do
      stub_broker_response([ line ])

      assert_equal({ assessed: false, nka: false, allergies: [ entry_for(line) ], conflict: true },
        RpmsRpc::Allergy.assessment("42"), "#{line.inspect}: an allergen after a marker is never hidden")
    end

    define_method("test_marker_with_extra_non_blank_pieces_beside_a_row_keeps_both_#{i}") do
      stub_broker_response([ line, PENICILLIN_ROW ])
      result = RpmsRpc::Allergy.assessment("42")

      refute result[:nka]
      refute result[:assessed]
      assert_equal true, result[:conflict]
      assert_equal [ line, "PENICILLIN" ].sort, result[:allergies].map { |a| a[:raw] || a[:allergen] }.sort
    end
  end

  def test_the_exact_marker_with_only_blank_extra_pieces_is_still_a_marker
    stub_broker_response([ "^No Known Allergies^^", "^No Known Allergies^ ^​" ])
    result = RpmsRpc::Allergy.assessment("42")

    assert_equal true, result[:conflict], "two markers"
    assert_equal [], result[:allergies], "blank extra pieces carry no text"
    refute result[:nka]
  end

  ALLERGEN_TEXT_OUTSIDE_PIECE_TWO = [
    [ PENICILLIN_ROW, "LATEX" ],
    [ PENICILLIN_ROW, "x^^LATEX" ],
    [ "^^LATEX^SEVERE" ],
    [ [ "5^LATEX" ] ],
    [ PENICILLIN_ROW, [ "5^LATEX" ] ]
  ].freeze

  ALLERGEN_TEXT_OUTSIDE_PIECE_TWO.each_with_index do |lines, i|
    define_method("test_allergen_text_outside_piece_two_is_surfaced_flagged_#{i}") do
      stub_broker_response(lines)
      result = RpmsRpc::Allergy.assessment("42")

      refute result[:nka]
      refute result[:assessed]
      assert_equal true, result[:conflict]
      assert_includes result[:allergies].map { |a| a[:raw] }.compact.join("|"), "LATEX", "#{lines.inspect}: LATEX must not be hidden"
    end
  end

  def test_a_nested_array_element_is_flattened_and_surfaced
    stub_broker_response([ [ "5^LATEX" ] ])

    assert_equal({ assessed: false, nka: false, allergies: [ entry_for("5^LATEX") ], conflict: true },
      RpmsRpc::Allergy.assessment("42"))
  end

  NON_CANONICAL_IEN_ROWS = [
    "667 ^LATEX", " 667^LATEX", "\t667^LATEX", "667​^LATEX", "​667^LATEX", "667 ^LATEX", "667^", "667"
  ].freeze

  NON_CANONICAL_IEN_ROWS.each_with_index do |line, i|
    define_method("test_an_ien_shape_orqqal_cannot_emit_is_never_vouched_for_#{i}") do
      stub_broker_response([ line ])
      result = RpmsRpc::Allergy.assessment("42")

      refute result[:assessed], "#{line.inspect}: no whitespace or invisible tolerance in the IEN, and a row needs allergen text"
      refute result[:nka]
      assert_equal true, result[:conflict]
      assert_equal [ line ], result[:allergies].map { |a| a[:raw] }, "#{line.inspect}: surfaced, not dropped"
    end
  end

  def test_clean_rows_carry_no_unrecognised_key_even_in_a_conflicting_reply
    stub_broker_response([ PENICILLIN_ROW, "-3^LATEX^SEVERE" ])
    clean, flagged = RpmsRpc::Allergy.assessment("42")[:allergies]

    refute_includes clean.keys, :unrecognised
    assert_equal "PENICILLIN", clean[:allergen]
    assert_equal true, flagged[:unrecognised]
  end

  def test_for_patient_returns_the_surfaced_entries_too
    stub_broker_response([ PENICILLIN_ROW, "-3^LATEX^SEVERE" ])

    assert_equal [ "PENICILLIN", "-3^LATEX^SEVERE" ], RpmsRpc::Allergy.for_patient("42").map { |a| a[:allergen] }
  end

  # Framing (RS/US). The evidence: ORQQAL LIST is an ARRAY return, which XwbClient
  # splits at CR/LF only; CiaClient splits at RS and drops the lone US node; BmxClient
  # is not the transport of a stock RPC. No client delivers RS/US inside a line of
  # this reply, so nothing strips them: a framing byte is not data the reply may
  # carry, and the exact NKA marker is byte-exact.

  def test_a_framing_only_element_beside_the_marker_is_never_nka
    [ [ "^No Known Allergies", "\u001E\u001F" ], [ "\u001E", "^No Known Allergies" ],
      [ "^No Known Allergies", "\u001F" ], [ "\u001E\u001F", "^No Known Allergies", "\u001E" ] ].each do |lines|
      stub_broker_response(lines)
      result = RpmsRpc::Allergy.assessment("42")

      refute result[:nka], lines.inspect
      refute result[:assessed], lines.inspect
      assert_equal true, result[:conflict], lines.inspect
      assert_equal lines.reject { |l| l == "^No Known Allergies" }, result[:allergies].map { |a| a[:raw] },
        "#{lines.inspect}: framing-only content is surfaced with its raw bytes, never dropped"
    end
  end

  def test_framing_glued_to_the_marker_is_not_the_exact_marker
    [ "^No Known Allergies\u001F", "^No Known Allergies\u001E\u001F", "\u001E^No Known Allergies" ].each do |line|
      stub_broker_response([ line ])
      result = RpmsRpc::Allergy.assessment("42")

      refute result[:nka], line.inspect
      refute result[:assessed], line.inspect
      assert_equal true, result[:conflict], line.inspect
    end
  end

  def test_a_nested_exact_marker_is_never_nka
    [ [ [ "^No Known Allergies" ] ], [ [ [ "^No Known Allergies" ] ] ] ].each do |lines|
      stub_broker_response(lines)
      result = RpmsRpc::Allergy.assessment("42")

      refute result[:nka], lines.inspect
      refute result[:assessed], lines.inspect
      assert_equal true, result[:conflict], lines.inspect
    end
  end

  def test_an_invalid_byte_inside_the_ien_is_not_dropped_to_make_a_row
    stub_broker_response([ "66\xFF7^LATEX^SEVERE".dup.force_encoding("UTF-8") ])
    result = RpmsRpc::Allergy.assessment("42")

    refute result[:assessed], "66<invalid>7 is not the IEN 667"
    assert_equal true, result[:conflict]
    assert_equal 1, result[:allergies].length
    assert_equal true, result[:allergies].first[:unrecognised]
  end

  # -- Panel round 4 on #483 ------------------------------------------------

  # (1) A clean row's OUTPUT is the original bytes (identical to main); only
  # classification may use a scrubbed copy. XWB delivers BINARY strings.

  def test_a_clean_binary_row_keeps_its_original_bytes_and_encoding
    [ "1^CAF\xC9^SEVERE".b, "1^CAF\xC3\x89^SEVERE".b ].each do |row|
      stub_broker_response([ row ])
      result = RpmsRpc::Allergy.assessment("42")

      assert result[:assessed], row.inspect
      refute_includes result.keys, :conflict, "#{row.inspect}: a Latin-1 byte in the allergen is the boundary's concern, not a conflict"
      allergen = result[:allergies].first[:allergen]
      assert_equal row.split("^")[1].b, allergen.b, "#{row.inspect}: the allergen bytes are the original bytes"
      assert_equal Encoding::BINARY, allergen.encoding, "#{row.inspect}: the encoding is not changed"
    end
  end

  def test_a_clean_latin_1_tagged_row_keeps_its_original_bytes_and_encoding
    row = "1^CAF\xC9^SEVERE".dup.force_encoding("ISO-8859-1")
    stub_broker_response([ row ])
    result = RpmsRpc::Allergy.assessment("42")

    assert result[:assessed]
    refute_includes result.keys, :conflict
    assert_equal "CAF\xC9".b, result[:allergies].first[:allergen].b
    assert_equal Encoding::ISO_8859_1, result[:allergies].first[:allergen].encoding
  end

  def test_a_mangled_marker_with_an_invalid_byte_is_not_a_marker
    [ [ "^No Known\xFF Allergies".b ], [ "^No Known\xFF Allergies".b, "1^X^S" ], [ "^No Known Allergies\xFF".dup.force_encoding("UTF-8") ] ].each do |lines|
      stub_broker_response(lines)
      result = RpmsRpc::Allergy.assessment("42")

      refute result[:nka], lines.inspect
      refute result[:assessed], lines.inspect
      assert_equal true, result[:conflict], "#{lines.inspect}: scrubbed to U+FFFD for matching, so it is unrecognised, not a marker"
      assert_equal lines.first.b, result[:allergies].first[:raw].b, "raw keeps the original bytes"
      assert result[:allergies].first[:allergen].valid_encoding?, "allergen is the displayable copy"
    end
  end

  # (2) A nested list, even an empty one, is unrecognised; nothing vanishes.

  def test_an_empty_or_blank_nested_list_is_unrecognised_and_surfaced
    [ [ "^No Known Allergies", [] ], [ "^No Known Allergies", [ "" ] ], [ "^No Known Allergies", [ [ [] ] ] ],
      [ "^No Known Allergies", [ "\r" ] ], [ [], PENICILLIN_ROW ] ].each do |lines|
      stub_broker_response(lines)
      result = RpmsRpc::Allergy.assessment("42")

      refute result[:nka], lines.inspect
      refute result[:assessed], lines.inspect
      assert_equal true, result[:conflict], lines.inspect
      assert_equal 1, result[:allergies].count { |a| a[:unrecognised] && a[:raw].start_with?("[") }, "#{lines.inspect}: the nested list is surfaced as a flagged entry"
    end
  end

  def test_an_empty_nested_list_surfaces_its_inspect_text
    stub_broker_response([ "^No Known Allergies", [] ])

    assert_equal [ { ien: nil, allergen: "[]", raw: "[]", unrecognised: true } ], RpmsRpc::Allergy.assessment("42")[:allergies]
  end

  # (3) A row needs VISIBLE allergen text; nothing is stripped to make it clean.

  NO_VISIBLE_ALLERGEN = [ "7^\u001F", "7^\u001E", "7^\u0000", "7^\xFF".b, "7^\xFF".dup.force_encoding("UTF-8"), "7^ ", "7^​", "7^\u001E\u001F" ].freeze

  NO_VISIBLE_ALLERGEN.each_with_index do |row, i|
    define_method("test_a_row_whose_allergen_piece_has_no_visible_text_is_not_clean_#{i}") do
      stub_broker_response([ row ])
      result = RpmsRpc::Allergy.assessment("42")

      refute result[:assessed], row.inspect
      refute result[:nka]
      assert_equal true, result[:conflict], row.inspect
    end
  end

  def test_a_row_carrying_framing_or_control_bytes_is_not_clean_even_with_visible_text
    [ "1^PEANUT\u001F", "1^PEANUT\u001E", "1^PEA\u0000NUT^SEVERE", "1^PEANUT^SEVERE^HIVES\u001E\u001F" ].each do |row|
      stub_broker_response([ row ])
      result = RpmsRpc::Allergy.assessment("42")

      refute result[:assessed], row.inspect
      assert_equal true, result[:conflict], row.inspect
      assert_includes result[:allergies].map { |a| a[:raw] }, row, "#{row.inspect}: surfaced, not stripped into a clean row"
    end
  end

  # (4) The invisible set is genuinely invisible characters only, not all of \p{Cf}.

  VISIBLE_FORMAT_CHARACTERS = [ "؀", "؁", "؅", "۝", "܏", "\u{110BD}", "‎", "‏" ].freeze

  VISIBLE_FORMAT_CHARACTERS.each_with_index do |char, i|
    define_method("test_a_visible_format_character_is_data_not_blank_#{i}") do
      stub_broker_response([ "^No Known Allergies", char ])
      result = RpmsRpc::Allergy.assessment("42")

      refute result[:nka], char.inspect
      refute result[:assessed]
      assert_equal true, result[:conflict], "#{char.inspect} is visible (or not provably invisible), so it is a line, not blank"
    end
  end

  GENUINELY_INVISIBLE = [ "​", "‌", "‍", "⁠", "⁡", "⁢", "⁣", "⁤", "﻿", "­",
                          "͏", "᠎", "\u{E0020}", "\u{E007F}", "️", "︀", "\u{E0100}" ].freeze

  # An invisible-only ELEMENT is content ORQQAL cannot emit: loud, never NKA.
  GENUINELY_INVISIBLE.each_with_index do |char, i|
    define_method("test_an_invisible_only_element_beside_the_marker_is_a_conflict_not_nka_#{i}") do
      stub_broker_response([ "^No Known Allergies", char ])
      result = RpmsRpc::Allergy.assessment("42")

      refute result[:nka], char.inspect
      refute result[:assessed], char.inspect
      assert_equal true, result[:conflict], char.inspect
      assert_equal [ char ], result[:allergies].map { |a| a[:raw] }, "#{char.inspect}: raw preserved"
    end
  end

  # (5) Depth cap and encodings that cannot be transcoded.

  def test_a_cyclic_reply_raises_a_typed_error
    cycle = []
    cycle << cycle
    stub_broker_response(cycle)

    error = assert_raises(RpmsRpc::Allergy::ReplyTooDeepError) { RpmsRpc::Allergy.assessment("42") }
    assert_kind_of RpmsRpc::Error, error
  end

  def test_nesting_beyond_the_cap_raises_a_typed_error_and_within_it_is_a_conflict
    deep = ->(levels) { levels.times.inject(PENICILLIN_ROW) { |inner, _| [ inner ] } }

    stub_broker_response(deep.call(200))
    assert_raises(RpmsRpc::Allergy::ReplyTooDeepError) { RpmsRpc::Allergy.assessment("42") }

    stub_broker_response(deep.call(RpmsRpc::Allergy::MAX_DEPTH))
    result = RpmsRpc::Allergy.assessment("42")
    assert_equal true, result[:conflict]

    stub_broker_response(deep.call(RpmsRpc::Allergy::MAX_DEPTH + 1))
    assert_raises(RpmsRpc::Allergy::ReplyTooDeepError) { RpmsRpc::Allergy.assessment("42") }
  end

  def test_a_string_in_an_encoding_with_no_converter_does_not_raise
    [ "1^LATEX^SEVERE".dup.force_encoding("UTF-7"), "^No Known Allergies".dup.force_encoding("UTF-7") ].each do |line|
      stub_broker_response([ line ])
      result = RpmsRpc::Allergy.assessment("42")

      refute result[:nka], line.inspect
      refute result[:assessed], line.inspect
      assert_equal true, result[:conflict], line.inspect
    end
  end

  # (6) The invalid-UTF-8 line-split branch must split: a marker is never buried
  # in the severity or signs of the row before it.

  SPLIT_TERMINATORS = { "CRLF" => "\r\n", "LF" => "\n", "CR" => "\r" }.freeze

  SPLIT_TERMINATORS.each do |name, br|
    [ [ "binary", ->(t) { t.b } ], [ "latin-1 tagged", ->(t) { t.dup.force_encoding("ISO-8859-1") } ] ].each do |tag, tagger|
      slug = "#{tag}_#{name}".gsub(/\W+/, "_")

      define_method("test_an_invalid_utf8_string_is_still_split_into_lines_#{slug}") do
        stub_broker_response(tagger.call("1^CAF\xC9^SEVERE#{br}^No Known Allergies"))
        result = RpmsRpc::Allergy.assessment("42")

        refute result[:nka]
        refute result[:assessed]
        assert_equal true, result[:conflict], "the marker is its own line"
        assert_equal 1, result[:allergies].length
        assert_equal "SEVERE", result[:allergies].first[:severity]
        assert_nil result[:allergies].first[:signs], "the marker is not buried in the signs"
      end

      define_method("test_an_invalid_utf8_array_element_is_still_split_into_lines_#{slug}") do
        stub_broker_response([ tagger.call("1^CAF\xC9^SEVERE#{br}^No Known Allergies") ])
        result = RpmsRpc::Allergy.assessment("42")

        assert_equal true, result[:conflict]
        assert_nil result[:allergies].first[:signs]
      end
    end
  end

  # -- NKA tightening (security review of #483): blank means EMPTY ------------
  # Only a truly empty segment (an empty-string element, or what splitting a
  # String leaves between terminators) is ignorable. Whitespace-only or
  # invisible-only content is a shape ORQQAL cannot emit: unrecognised.

  NKA_TABLE_MARKER = "^No Known Allergies"

  NKA_SHAPES = {
    nka: {
      "exact array" => [ NKA_TABLE_MARKER ],
      "exact + empty string" => [ NKA_TABLE_MARKER, "" ],
      "empty strings around" => [ "", NKA_TABLE_MARKER, "" ],
      "string crlf" => "#{NKA_TABLE_MARKER}\r\n",
      "string lead cr" => "\r#{NKA_TABLE_MARKER}",
      "string lf" => "#{NKA_TABLE_MARKER}\n",
      "string empty segment" => "#{NKA_TABLE_MARKER}\n\n"
    },
    conflict: {
      "space element" => [ NKA_TABLE_MARKER, " " ],
      "tab element" => [ NKA_TABLE_MARKER, "\t" ],
      "nbsp element" => [ NKA_TABLE_MARKER, " " ],
      "zwsp element" => [ NKA_TABLE_MARKER, "​" ],
      "word joiner element" => [ NKA_TABLE_MARKER, "⁠" ],
      "soft hyphen element" => [ NKA_TABLE_MARKER, "­" ],
      "variation selector element" => [ NKA_TABLE_MARKER, "️" ],
      "tag char element" => [ NKA_TABLE_MARKER, "\u{E0041}" ],
      "whitespace element before" => [ " ", NKA_TABLE_MARKER ],
      "string marker + zwsp line" => "#{NKA_TABLE_MARKER}\n​\n",
      "string marker + space line" => "#{NKA_TABLE_MARKER}\n  ",
      "string zwsp line + marker" => "​\n#{NKA_TABLE_MARKER}",
      "fullwidth caret" => [ "＾No Known Allergies" ],
      "extra piece nonblank" => [ "#{NKA_TABLE_MARKER}^LATEX" ],
      "nested exact" => [ [ NKA_TABLE_MARKER ] ],
      "whitespace only reply" => [ " " ]
    },
    lone_marker: {
      "zwsp before marker" => [ "​#{NKA_TABLE_MARKER}" ],
      "zwsp after marker" => [ "#{NKA_TABLE_MARKER}​" ],
      "zwsp inside marker" => [ "^No Known​Allergies" ],
      "case variant" => [ "^no known allergies" ],
      "extra piece blank" => [ "#{NKA_TABLE_MARKER}^" ],
      "nul after" => [ "#{NKA_TABLE_MARKER}\u0000" ],
      "element with terminator" => [ "#{NKA_TABLE_MARKER}\n" ],
      "element with leading terminator" => [ "\n#{NKA_TABLE_MARKER}" ]
    }
  }.freeze

  NKA_SHAPES.each do |kind, shapes|
    shapes.each do |name, response|
      define_method("test_nka_table_#{kind}_#{name.gsub(/\W+/, '_')}") do
        stub_broker_response(response)
        result = RpmsRpc::Allergy.assessment("42")

        case kind
        when :nka
          assert_equal({ assessed: true, nka: true, allergies: [] }, result, name)
        when :lone_marker
          assert_equal({ assessed: false, nka: false, allergies: [] }, result, name)
        else
          refute result[:nka], name
          refute result[:assessed], name
          assert_equal true, result[:conflict], name
        end
      end
    end
  end

  # -- C1 controls in a clean row (security review of #483) -------------------
  # A byte 0x80-0x9F in a BINARY / Latin-1 / Windows-1252 string is a byte (a
  # printable character in Windows-1252), so the row stays clean and its bytes
  # are untouched. A real U+0080-U+009F CODEPOINT in valid UTF-8 (NEL, CSI...)
  # is a control sequence, not text: unrecognised. Unproven: which charset a
  # live site uses (rpms-rpc#476).

  def test_c1_bytes_in_a_binary_row_stay_clean_and_byte_identical
    [ "\x80", "\x85", "\x96", "\x9B", "\x9F" ].each do |byte|
      row = "1^A#{byte}B^SEVERE".b
      stub_broker_response([ row ])
      result = RpmsRpc::Allergy.assessment("42")

      assert result[:assessed], byte.inspect
      refute_includes result.keys, :conflict, byte.inspect
      assert_equal "A#{byte}B".b, result[:allergies].first[:allergen].b
      assert_equal Encoding::BINARY, result[:allergies].first[:allergen].encoding
    end
  end

  def test_c1_bytes_in_latin_1_and_windows_1252_tagged_rows_stay_clean
    [ "ISO-8859-1", "Windows-1252" ].each do |encoding|
      row = "1^A\x96B^SEVERE".dup.force_encoding(encoding)
      stub_broker_response([ row ])
      result = RpmsRpc::Allergy.assessment("42")

      assert result[:assessed], encoding
      refute_includes result.keys, :conflict, encoding
    end
  end

  def test_a_real_c1_codepoint_in_valid_utf_8_is_unrecognised
    [ "\u0080", "\u0090", "\u009B", "\u009F" ].each do |char|
      [ "1^A#{char}B^SEVERE", "1^A#{char}B^SEVERE".b ].each do |row|
        stub_broker_response([ row ])
        result = RpmsRpc::Allergy.assessment("42")

        refute result[:assessed], "#{char.inspect} #{row.encoding}: a control sequence is not text"
        assert_equal true, result[:conflict], char.inspect
        assert_equal [ row.b ], result[:allergies].map { |a| a[:raw].b }, "surfaced, not dropped"
      end
    end
  end

  def test_a_c1_codepoint_in_a_different_piece_of_a_utf_8_row_is_unrecognised_too
    stub_broker_response([ "1^LATEX^SEV\u009BERE" ])

    assert_equal true, RpmsRpc::Allergy.assessment("42")[:conflict]
  end

  # -- Fail-closed when the parser drops a row -------------------------------

  def test_a_clean_row_the_parser_drops_is_never_a_silent_clean_reply
    mapping = RpmsRpc::DataMapper[:allergy_list]
    mapping.define_singleton_method(:parse_many) { |_rows| [] } # a parser that drops every row
    begin
      stub_broker_response([ PENICILLIN_ROW ])
      result = RpmsRpc::Allergy.assessment("42")

      refute result[:assessed], "a row that is not parsed must not read as assessed"
      assert_equal true, result[:conflict]
      assert_includes result[:allergies].map { |a| a[:raw] }, PENICILLIN_ROW, "and it is surfaced, not lost"
    ensure
      mapping.singleton_class.send(:remove_method, :parse_many)
    end
  end

  # The invisible set is narrow: a visible format character is text.
  def test_a_row_whose_allergen_is_a_visible_format_character_is_clean
    [ "\u0600", "\u06DD", "\u070F", "\u{110BD}" ].each do |char|
      stub_broker_response([ "7^#{char}^SEVERE" ])
      result = RpmsRpc::Allergy.assessment("42")

      assert result[:assessed], char.inspect
      refute_includes result.keys, :conflict, char.inspect
    end
  end

  def test_a_marker_followed_by_a_visible_format_character_is_not_a_marker
    stub_broker_response([ "^No Known Allergies\u0600" ])
    result = RpmsRpc::Allergy.assessment("42")

    refute result[:nka]
    assert_equal true, result[:conflict], "U+0600 is visible text, so this is an unrecognised line"
  end
end
