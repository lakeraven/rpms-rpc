# frozen_string_literal: true

require_relative "live_helper"
require_relative "wire_reads"
require "rpms_rpc/api/vital"

# Reads VueCentric's chart components make as a patient's chart opens and a
# visit is worked, sent with the parameters the client sends in a recorded
# session, each checked against the file it reads or against the stock read
# that answers the same question: the CWAD letters (BEHOCACV CWAD), the
# visit list and one visit's data (BEHOENCV LIST, BEHOENP1 LOAD), the problem
# list (BEHOPLCV LIST), the duplicate-patient check (BEHOPTCX CHKDUP), the
# triage summary (BGOTRG GETSUM), the vital the medication order shows
# (BEHORXFN VITALFMT), and the pick lists behind PCC data entry (BEHOENP1
# EXAMCODE, BGOUTL DICLKUP, BGOUTL3 GETSET, BGOSNLK SUBSET, BGOSNOPR GETCATS
# and GETITEMS, BGOCPTPR GETCATS and GETITEMS, BGOPROB2 MAP). Read only.
class ChartComponentReadsLiveTest < LiveSpec::Test
  include WireReads

  runs_as :provider

  VITALS_DFN = 2 # the demo patient with vitals and a PENICILLIN allergy
  NOTES_DFN = 4 # DEMO,PATIENT ONE: notes, a CLINICAL WARNING, a BEE POLLEN allergy, problems
  VITALS_VISIT = 1 # VITALS_DFN's seeded visit, with the vitals and two procedures

  # CWAD^BEHOCACV (BEHOCACV.m:22-34) gathers the same postings and allergies
  # ORWPT CWAD does; the letters agree, and follow the files: an allergy on
  # #120.8 is A, a CLINICAL WARNING note is W.
  def test_cwad_letters_agree_with_the_stock_read_and_the_files
    allergic = listed("120.8", ".01").map { |e| e[:pieces][0] }
    [ VITALS_DFN, NOTES_DFN ].each do |dfn|
      letters = value("BEHOCACV CWAD", dfn.to_s)
      assert_equal value("ORWPT CWAD", dfn.to_s), letters, "DFN #{dfn}"
      assert_includes letters, "A", "DFN #{dfn} has an allergy on #120.8" if allergic.include?(dfn.to_s)
    end
    assert_equal "WA", value("BEHOCACV CWAD", NOTES_DFN.to_s), "DFN #{NOTES_DFN}: a CLINICAL WARNING note and an allergy"
  end

  # LIST^BEHOENCV (BEHOENCV.m:5-7) is VISITLST^BEHOENCX's list: VISIT STRING
  # (location;date;category;visit IEN)^LOCATION^DATE^CATEGORY^LOCKED^PROVIDER
  # IEN^PROVIDER^1. Each row is one of the patient's VISIT (#9000010) entries.
  def test_visit_list_rows_are_the_patients_visits
    got = rows("BEHOENCV LIST", NOTES_DFN.to_s).map { |r| pieces(r) }
    refute_empty got, "DFN #{NOTES_DFN} has visits on the demo build"
    got.each do |row|
      loc, date, _category, ien = row[0].split(";")
      filed = entry("9000010", ien, ".01;.05;.22")
      assert_equal NOTES_DFN.to_s, filed.dig(".05", :internal), "visit #{ien} is the patient's"
      assert_equal filed.dig(".01", :internal), date, "visit #{ien}'s date"
      assert_equal filed.dig(".01", :internal), row[2]
      assert_equal filed.dig(".22", :internal).to_s, loc.to_s, "visit #{ien}'s location"
    end
    dates = got.map { |r| r[2].to_f }
    assert_equal dates.sort.reverse, dates, "newest first"
    assert_empty rows("BEHOENCV LIST", "999999999").reject(&:empty?)
  end

  # LOAD^BEHOENP1 (BEHOENP1.m:5-): HDR^IS INPATIENT^^VISIT STRING, then the
  # visit's own fields (VST^DT, VST^PT, VST^HL) and its V file entries.
  def test_one_visits_data_entry_load_is_that_visit
    visit = pieces(rows("BEHOENCV LIST", NOTES_DFN.to_s).first)[0]
    ien = visit.split(";").last
    filed = entry("9000010", ien, ".01;.05;.22")
    got = rows("BEHOENP1 LOAD", NOTES_DFN.to_s, ien)
    assert_equal "HDR^0^^#{visit}", got.first, "the header carries the visit string"
    assert_includes got, "VST^DT^#{filed.dig('.01', :internal)}"
    assert_includes got, "VST^PT^#{NOTES_DFN}"
    assert(got.any? { |r| r.start_with?("VST^HL^#{filed.dig('.22', :internal)}^^") }, got.inspect)
    assert_empty rows("BEHOENP1 LOAD", NOTES_DFN.to_s, "0").reject(&:empty?), "no visit, no rows"
  end

  # LIST^BEHOPLCV (BEHOPLCV.m:5-13) is LIST^GMPLUTL3: IFN^STATUS^NARRATIVE^
  # ICD^ONSET^LAST MODIFIED^...^SNOMED CT concept^designation. Checked
  # against PROBLEM (#9000011): status .12, onset .13, last modified .03.
  def test_problem_list_rows_are_the_patients_problems
    got = rows("BEHOPLCV LIST", NOTES_DFN.to_s, "A").map { |r| pieces(r) }
    filed = listed("9000011", ".02;.12;.13;.03").select { |e| e[:pieces][0] == NOTES_DFN.to_s }
    active = filed.reject { |e| e[:pieces][1] == "I" }
    assert_equal active.map { |e| e[:ien].to_s }.sort, got.map(&:first).sort, "every problem not inactive, and only those"
    got.each do |row|
      on_file = active.find { |e| e[:ien].to_s == row[0] }
      assert_equal on_file[:pieces][1], row[1], "problem #{row[0]} status"
      assert_equal on_file[:pieces][2].to_s, row[4], "problem #{row[0]} onset"
      assert_equal on_file[:pieces][3], row[5], "problem #{row[0]} last modified"
      refute_empty row[2].strip, "problem #{row[0]} has a narrative"
    end
    assert(got.any? { |r| r[2].start_with?("Type 2 diabetes mellitus") && r[10] == "44054006" }, "DFN #{NOTES_DFN}'s seeded diabetes, SNOMED CT 44054006")
  end

  # CHKDUP^BEHOPTCX (BEHOPTCX.m:194-): GUIBS5A^DPTLK6's similar-patient
  # check; 0 when no other patient looks like this one.
  def test_a_seeded_patient_has_no_lookalike
    assert_equal "0", value("BEHOPTCX CHKDUP", NOTES_DFN.to_s)
  end

  # GETSUM^BGOTRG (BGOTRG.m:10-): a visit's triage summary, one header row
  # ^SECTION^STATE^COUNT before its lines. The vitals are the visit's V
  # MEASUREMENT entries, as BEHOVM lists them.
  def test_triage_summary_lists_the_visits_vitals
    got = rows("BGOTRG GETSUM", "#{VITALS_VISIT}^#{client.duz}^^1")
    header = got.index { |r| r.start_with?("^Vitals^") } || flunk("no vitals section: #{got.inspect}")
    count = pieces(got[header])[3].to_i
    vitals = got[header + 1, count]
    assert_equal count, vitals.size
    on_visit = listed("9000010.01", ".01;.03;.04").select { |e| e[:pieces][1] == VITALS_VISIT.to_s }
    assert_equal on_visit.size, vitals.size, "one line per V MEASUREMENT of visit #{VITALS_VISIT}"
    assert_includes vitals, "BP: 142/88 mmHg", "the seeded blood pressure"
    assert_empty rows("BGOTRG GETSUM", "999999999^#{client.duz}^^1").reject(&:empty?), "no visit, no summary"
  end

  # VITALFMT^BEHORXFN (BEHORXFN.m:402-408): DATE^VALUE^METRIC of the
  # patient's newest vital of a type, as the order dialog shows it; the
  # newest is the one BEHOVM LIST names.
  def test_order_dialog_vital_is_the_newest_of_its_type
    latest = RpmsRpc::Vital.latest_by_type(VITALS_DFN)
    %w[WT BP].each do |type|
      row = latest.find { |v| v[:abbreviation] == type } || flunk("no #{type} for DFN #{VITALS_DFN}")
      date, shown, metric = pieces(value("BEHORXFN VITALFMT", VITALS_DFN.to_s, type))
      assert_equal row[:taken_at].strftime("%m/%d/%Y"), date, "#{type} date"
      assert_equal row[:value].split.first, shown, "#{type} value"
      if type == "WT"
        assert_in_delta row[:value].to_f * 0.45359237, metric.to_f, 0.01, "the weight in kg"
      else
        assert_empty metric.to_s
      end
    end
    assert_empty rows("BEHORXFN VITALFMT", VITALS_DFN.to_s, "").reject(&:empty?), "no type, no vital"
  end

  # EXAMCODE^BEHOENP1 (BEHOENP1.m:209-220): the results an exam (#9999999.15)
  # allows, CODE^TEXT, from its own result list (VXAMR^AUPNCIX).
  def test_exam_result_codes
    got = rows("BEHOENP1 EXAMCODE", "34").map { |r| pieces(r) }
    assert_includes got, %w[N NORMAL/NEGATIVE]
    assert_includes got, %w[PO POSITIVE]
    got.each { |code, text| assert_match(/\A[A-Z]+\z/, code) && refute_empty(text) }
    assert_empty rows("BEHOENP1 EXAMCODE", "").reject(&:empty?)
  end

  # DICLKUP^BGOUTL (BGOUTL.m:112-): a FileMan lookup, IEN^NAME^NAME; the
  # client lists READINESS TO LEARN (#99999.15) whole.
  def test_fileman_lookup_lists_the_whole_file
    got = rows("BGOUTL DICLKUP", "99999.15^^^1^^^^1^").map { |r| pieces(r) }
    filed = listed("99999.15", ".01").to_h { |e| [ e[:ien].to_s, e[:pieces][0] ] }
    assert_equal filed, got.to_h { |ien, name, _| [ ien, name ] }
    got.each { |_ien, name, shown| assert_equal name, shown }
    assert_includes filed.values, "EAGER TO LEARN"
  end

  # GETSET^BGOUTL3 (BGOUTL3.m:3-): a set-of-codes field's CODE^TEXT, from its
  # data dictionary; a field that is no set answers nothing.
  def test_set_of_codes_reads_the_fields_definition
    got = rows("BGOUTL3 GETSET", "9000010.07", ".11").map { |r| pieces(r) }
    assert_equal "A", got.first[0]
    assert_includes got, [ "A", "Home-inside" ]
    assert_includes got, [ "L", "Unknown" ]
    assert_equal got.map(&:first).uniq, got.map(&:first)
    assert_empty rows("BGOUTL3 GETSET", "9000010.07", ".01").reject(&:empty?), "V POV .01 is a pointer"
  end

  # SUBSET^BGOSNLK (BGOSNLK.m:32-): a BSTS subset's members, TEXT^
  # DESCRIPTION ID^CONCEPT ID^ICD^^TEXT.
  def test_snomed_subset_members
    got = rows("BGOSNLK SUBSET", "EHR IPL SEVERITY").map { |r| pieces(r) }
    mild = got.find { |r| r[0] == "Mild" } || flunk("no Mild in EHR IPL SEVERITY: #{got.first(3).inspect}")
    assert_equal "255604002", mild[2], "Mild is SNOMED CT 255604002"
    got.each do |row|
      assert_match(/\A\d+\z/, row[1], row.inspect)
      assert_match(/\A\d+\z/, row[2], row.inspect)
      assert_equal row[0], row[5]
    end
  end

  # GETCATS^BGOSNOPR and GETITEMS^BGOSNOPR (BGOSNOPR.m:25-): the SNOMED CT
  # pick list's categories, NAME^IEN^..., and a category's items, numbered,
  # N^TEXT^DESCRIPTION ID^CONCEPT ID^...^ICD. An unknown category is -1019.
  def test_snomed_pick_list
    cats = rows("BGOSNOPR GETCATS", "^6^#{client.duz}^^^").map { |r| pieces(r) }
    bh = cats.find { |c| c[0] == "Behavioral Health" } || flunk("no Behavioral Health category: #{cats.map(&:first)}")
    items = rows("BGOSNOPR GETITEMS", "#{bh[1]}^^^").map { |r| pieces(r) }
    refute_empty items
    assert_equal (1..items.size).map(&:to_s), items.map(&:first)
    items.each { |i| assert_match(/\A\d+\z/, i[3], i.inspect) }
    adjustment = items.find { |i| i[1] == "Adjustment disorder" } || flunk("no Adjustment disorder under Behavioral Health")
    assert_equal [ "17226007", "F43.20" ], adjustment.values_at(3, 11)
    assert_equal [ "-1019^Unknown category specified." ], rows("BGOSNOPR GETITEMS", "999999999^^^")
  end

  # GETCATS^BGOCPTPR and GETITEMS^BGOCPTPR (BGOCPTPR.m:27-): the CPT pick
  # list's categories, and a category's items; -1019 for an unknown one.
  def test_cpt_pick_list
    cats = rows("BGOCPTPR GETCATS", "^6^#{client.duz}^^^").map { |r| pieces(r) }
    refute_empty cats
    cats.each { |c| assert_operator c[1].to_i, :>, 0, c.inspect }
    assert_includes cats.map(&:first), "REHAB EQUIPMENT"
    cats.each { |c| refute_includes rows("BGOCPTPR GETITEMS", "#{c[1]}^6^^").join, "-1019", "#{c[0]} is a known category" }
    assert_equal [ "-1019^Unknown category specified." ], rows("BGOCPTPR GETITEMS", "999999999^6^^")
  end

  # MAP^BGOPROB2 (BGOPROB2.m:5-): per concept, C^CONCEPT, then its ICD-10 map
  # advice from BSTS, ~t^N^TEXT.
  def test_icd10_map_advice_for_a_concept
    got = rows("BGOPROB2 MAP", { "0" => "38341003" })
    assert_equal "C^38341003", got.first
    advice = got.drop(1).map { |r| pieces(r) }
    refute_empty advice
    assert_equal (1..advice.size).map(&:to_s), advice.map { |r| r[1] }
    assert advice.all? { |r| r[0] == "~t" }
    assert(advice.any? { |r| r[2].include?("Target Code: I10") }, "essential hypertension maps to I10")
  end
end
