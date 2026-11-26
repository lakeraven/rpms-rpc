# frozen_string_literal: true

require_relative "live_helper"
require_relative "wire_reads"

# Stock CPRS chart reads the VueCentric client's binaries name, registered in
# CIAV VUECENTRIC, for a patient with an allergy, a prescription, a consult,
# reminders and an appointment (DFN 2 on the demo build): an order's detail
# (ORQOR DETAIL), allergies (ORQQAL DETAIL, ORQQAL LIST REPORT), postings
# (ORQQPP LIST), consults (ORQQCN STATUS, URGENCIES, SVCLIST, GET SERVICE
# IEN, GET ORDER NUMBER, FIND CONSULT), reminders (ORQQPXRM REMINDER
# EVALUATION, DETAIL, INQUIRY, DIALOG ACTIVE), visits and admissions (ORWCV
# VST, ORWPT ADMITLST, ORWPT DISCHARGE, ORWPT CLINRNG), lab ordering lists
# (ORWLRR SPEC, CHEMTEST, INFO, PARAM) and a medication's history (ORWPS
# MEDHIST). Each is checked against the file it reads or the VueCentric
# read of the same data. Read only.
class StockChartReadsLiveTest < LiveSpec::Test
  include WireReads

  runs_as :provider

  DFN = 2
  NOTES_DFN = 4 # DEMO,PATIENT ONE, with a CLINICAL WARNING posting
  ORDER = 4 # DFN 2's seeded prescription
  CONSULT = 1 # DFN 2's seeded CARDIOLOGY consult
  DEPRESSION_SCREEN = 123

  # DETAIL^ORWOR: the order's text, its activity and its current data.
  def test_order_detail
    got = rows("ORQOR DETAIL", ORDER.to_s, DFN.to_s)
    assert_equal rows("ORWORR GETTXT", "#{ORDER};2").first.strip, got.first.strip, "the order's current text first"
    assert_includes got, "Activity:"
    assert_includes got, "Order ##{ORDER}"
    status = entry("100", ORDER, "5").dig("5", :external)
    assert(got.any? { |l| l.match?(/\ACurrent Status:\s+#{status}\z/) }, "status #{status}")
  end

  # DETAIL^ORQQAL (ORQQAL.m:130-) and LRPT^ORQQAL (ORQQAL.m:23-): one
  # allergy's detail and the report of all, as BEHOARCV shows them.
  def test_allergy_detail_and_report
    allergy = listed("120.8", ".01;.02").find { |e| e[:pieces][0] == DFN.to_s } || flunk("DFN #{DFN} has no allergy")
    detail = rows("ORQQAL DETAIL", DFN.to_s, allergy[:ien].to_s)
    assert_includes detail.map(&:strip), "Causative agent: #{allergy[:pieces][1]}"
    assert_includes detail.map(&:strip), "Signs/symptoms: HIVES"
    report = rows("ORQQAL LIST REPORT", DFN.to_s).map(&:strip)
    assert_equal allergy[:pieces][1], report.first
    assert_includes report, "Signs/symptoms: HIVES"
  end

  # LIST^ORQQPP (ORQQPP.m:3-): the patient's postings (ENCOVER^TIUPP3), as
  # BEHOCACV CWAD letters them: the CLINICAL WARNING note and the allergies.
  def test_postings
    got = rows("ORQQPP LIST", NOTES_DFN.to_s).map { |r| pieces(r) }
    warning = got.find { |r| r[1] == "CLINICAL WARNING" } || flunk("no CLINICAL WARNING posting: #{got.inspect}")
    note = entry("8925", warning[0], ".01;.02")
    assert_equal NOTES_DFN.to_s, note.dig(".02", :internal)
    assert_includes got.map { |r| r[1] }, "ALLERGIES"
    assert_equal "WA", value("BEHOCACV CWAD", NOTES_DFN.to_s)
  end

  # The consult reads: STATUS^ORQQCN2 (the statuses in use), URG^ORQQCN1
  # (the GMRCURGENCY protocols a consult may take), SVCLIST^ORQQCN2 (the same
  # services as ORQQCN SVC W/SYNONYMS), SVCIEN^ORQQCN2 (an orderable item's
  # service), GETORDER^ORQQCN1 (the consult's order), FINDCSLT^ORQQCN1 (the
  # consult's list row, as ORQQCN LIST gives it).
  def test_consult_reads
    statuses = pieces(value("ORQQCN STATUS"))
    assert_equal %w[999 OTHER], statuses[0, 2]
    assert_includes statuses[2].split(","), entry("123", CONSULT, "8").dig("8", :internal), "the consult's status is in use"

    urgencies = rows("ORQQCN URGENCIES", CONSULT.to_s).map { |r| pieces(r) }
    refute_empty urgencies
    urgencies.each do |protocol, name|
      assert_equal "GMRCURGENCY - #{name}", entry("101", protocol, ".01").dig(".01", :external), "urgency #{name} is its GMRCURGENCY protocol"
    end

    assert_equal rows("ORQQCN SVC W/SYNONYMS", "1", "1", "1", "0"), rows("ORQQCN SVCLIST", "", "1")
    service = entry("123", CONSULT, "1").dig("1", :internal)
    item = pieces(rows("ORQQCN SVCLIST", "", "1").find { |r| pieces(r)[0] == service })[5]
    assert_equal service, value("ORQQCN GET SERVICE IEN", item), "orderable item #{item} is service #{service}"

    order = value("ORQQCN GET ORDER NUMBER", CONSULT.to_s)
    assert_equal "#{DFN};DPT(", entry("100", order, ".02").dig(".02", :internal), "the consult's order is the patient's"
    assert_equal rows("ORQQCN LIST", DFN.to_s).first, value("ORQQCN FIND CONSULT", CONSULT.to_s)
    assert_equal "-1^Consult not found", value("ORQQCN FIND CONSULT", "999999999")
  end

  # The reminder reads (PXRMRPCA, PXRMRPCC): ALIST evaluates the reminder for
  # the patient as BEHORMCV LIST does; REMDET shows its status; RES is the
  # reminder's inquiry by its #811.9 name; ACTIVE says whether it has an
  # active dialog.
  def test_reminder_reads
    evaluated = pieces(value("ORQQPXRM REMINDER EVALUATION", DFN.to_s, { "1" => DEPRESSION_SCREEN.to_s }))
    cover = pieces(rows("BEHORMCV LIST", DFN.to_s, "0").find { |r| r.start_with?("#{DEPRESSION_SCREEN}^") })
    assert_equal cover[0, 3], evaluated[0, 3], "the same reminder, name and status the cover sheet shows"

    detail = rows("ORQQPXRM REMINDER DETAIL", DFN.to_s, DEPRESSION_SCREEN.to_s)
    assert_match(/--STATUS--/, detail.first)
    assert_match(/\A\s*#{Regexp.escape(cover[2])}/, detail[1], "the detail's status is the evaluation's")

    reminder = entry("811.9", DEPRESSION_SCREEN, ".01;51")
    inquiry = rows("ORQQPXRM REMINDER INQUIRY", DEPRESSION_SCREEN.to_s)
    assert inquiry.first.start_with?(reminder.dig(".01", :external)), inquiry.first
    dialog = reminder.dig("51", :internal).to_s
    has_dialog = !dialog.empty? && entry("801.41", dialog, "3").dig("3", :internal).to_s.empty? ? "1" : "0"
    assert_equal "#{DEPRESSION_SCREEN}^#{has_dialog}", value("ORQQPXRM DIALOG ACTIVE", { DEPRESSION_SCREEN.to_s => DEPRESSION_SCREEN.to_s }),
                 "the list's subscripts are the reminders (ACTIVE^PXRMRPCC)"
  end

  # VST1^ORWCV: the patient's appointments and visits in a range, A;DATE;
  # LOCATION^DATE^LOCATION NAME^STATUS for an appointment; ADMITLST^ORWPT:
  # the admissions (none for an outpatient); DISCHRG^ORWPT: today when there
  # is no admission; CLINRNG^ORWPT: the appointment ranges offered.
  def test_visits_admissions_and_ranges
    clinics = listed("44", ".01").to_h { |e| [ e[:ien].to_s, e[:pieces][0] ] }
    got = rows("ORWCV VST", DFN.to_s, "3260101", "3271231", "").map { |r| pieces(r) }
    got.each do |id, date, name|
      kind, at, loc = id.split(";")
      assert_equal "A", kind, "an appointment: #{id}"
      assert_equal at, date
      assert_equal clinics[loc], name, "appointment at #{loc}"
    end
    assert_empty rows("ORWPT ADMITLST", DFN.to_s).reject(&:empty?), "DFN #{DFN} was never admitted"
    assert_equal fm_today.to_s, value("ORWPT DISCHARGE", DFN.to_s, "0")
    ranges = rows("ORWPT CLINRNG").map { |r| pieces(r) }
    assert_includes ranges, %w[T;T Today]
    assert_includes ranges, [ "T-7;T", "Past Week" ]
  end

  # The lab ordering lists (LR7OGO): specimens (TOPOGRAPHY #61) and chemistry
  # tests (LABORATORY TEST #60, by name or synonym) from a name; INFO describes a
  # test; PARAM is the lab's ordering parameters.
  def test_lab_ordering_lists
    specimens = rows("ORWLRR SPEC", "A", "1").map { |r| pieces(r) }
    refute_empty specimens
    specimens.first(10).each { |ien, name| assert entry("61", ien, ".01").dig(".01", :external).start_with?(name), "specimen #{ien}, #{name} (names are cut to 30)" }
    tests = rows("ORWLRR CHEMTEST", "A", "1").map { |r| pieces(r) }
    refute_empty tests
    tests.first(10).each do |ien, name|
      indexed = RpmsRpc::DdrFileman.list_all(file: "60", fields: ".01", part: name, xref: "B").map { |e| e[:ien].to_s }
      assert_includes indexed, ien, "#{name} is test #{ien}'s name or synonym on the B index"
    end
    test = tests.first[0]
    assert_equal entry("60", test, ".01").dig(".01", :external), rows("ORWLRR INFO", test).first, "INFO opens with the test's name"
    assert_operator pieces(value("ORWLRR PARAM")).size, :>=, 5
  end

  # MEDHIST^ORWPS (ORWPS.m:179-): the administration history report for a
  # medication order.
  def test_medication_history
    got = rows("ORWPS MEDHIST", DFN.to_s, ORDER.to_s)
    assert(got.any? { |l| l.include?("MEDICATION HISTORY") }, got.first(6).inspect)
  end
end
