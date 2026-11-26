# frozen_string_literal: true

require_relative "live_helper"
require_relative "wire_reads"

# The lookups VueCentric's PCC components make while a provider charts a
# visit, sent with the parameters the client sends in a recorded session and
# checked against the file each reads: the clinics a visit may be at (BEHOENCX
# CLINLOC, BEHOENCX ISSTOPCD), the patient's address and phones (BEHOPTCX
# PTINFO1), the exam, health factor and education pick lists (BGOVEXAM
# GETTYPES, BGOVHF GETTYPES, BGOVPED GETTYPES, BGOVPED GETNAME), the chief
# complaint pick list (BGOCC GETPL), and the problem entry checks (BGOPROB
# NEXTID, BGOASLK CHKASM, BGOVPOV1 QUALLK, BGOVPOV1 FRAC, BGOVPOV2 INJURY).
# Read only.
class PccPickListReadsLiveTest < LiveSpec::Test
  include WireReads

  runs_as :provider

  DFN = 4 # DEMO,PATIENT ONE, with four problems on the integrated list
  VISIT = 1 # a seeded visit, for the date the injury check reads
  INFLUENZA = "6142004" # SNOMED CT, ICD-10 J11.1: not an injury, not a fracture
  FEMUR_FRACTURE = "71620000" # SNOMED CT fracture of femur
  ASTHMA = [ "J45.909", "195967001" ].freeze # an asthma ICD-10 code and its SNOMED CT concept

  # CLINLOC^BEHOENCX (HOSPLOC with TYPE C, BEHOENCX.m:198-): active clinics
  # (HOSPITAL LOCATION #44 TYPE C) in name order, IEN^NAME^ABBREVIATION.
  # ISSTOPCD (BEHOENCX.m:372-374): is the clinic's stop code the one given.
  def test_clinics_a_visit_may_be_at
    clinics = listed("44", ".01;2").select { |e| e[:pieces][1] == "C" }.to_h { |e| [ e[:ien].to_s, e[:pieces][0] ] }
    got = rows("BEHOENCX CLINLOC", "", "1").map { |r| pieces(r) }
    refute_empty got
    got.each { |ien, name| assert_equal clinics[ien], name, "clinic #{ien}" }
    names = got.map { |r| r[1] }
    assert_equal names.sort, names
    assert_includes got.map { |r| r[0, 2] }, [ "3", "DEMO IHS CLINIC" ]

    stop = entry("44", 3, "8").dig("8", :internal)
    code = stop.to_s.empty? ? nil : entry("40.7", stop, "1").dig("1", :internal)
    assert_equal "1", value("BEHOENCX ISSTOPCD", "3", code) if code
    assert_equal "0", value("BEHOENCX ISSTOPCD", "3", "999"), "not the clinic's stop code"
  end

  # PTINFO1^BEHOPTCX (BEHOPTCX.m:35-41): the patient's address (ADD^VADPT)
  # and phones (#2 .13): STREET 1^2^3^CITY^STATE^ZIP^^HOME^WORK^...
  def test_patient_address_and_phones
    got = pieces(value("BEHOPTCX PTINFO1", DFN.to_s))
    filed = entry("2", DFN, ".111;.114;.115;.116;.131;.132")
    assert_equal filed.dig(".111", :external), got[0]
    assert_equal filed.dig(".114", :external), got[3]
    assert_equal filed.dig(".115", :external), got[4]
    assert_equal filed.dig(".116", :external), got[5]
    assert_equal [ filed.dig(".131", :external), filed.dig(".132", :external) ], got.values_at(7, 8)
  end

  # GETTYPES^BGOVEXAM (BGOVEXAM.m:59-): active EXAM (#9999999.15) entries,
  # IEN^NAME^CODE^CPT.
  def test_exam_types
    exams = listed("9999999.15", ".01;.02").to_h { |e| [ e[:ien].to_s, e[:pieces] ] }
    got = rows("BGOVEXAM GETTYPES", "").map { |r| pieces(r) }
    refute_empty got
    got.each { |ien, name, code| assert_equal [ name, code ], exams[ien], "exam #{ien}" }
    assert_includes got.map { |r| r[1] }, "DEPRESSION SCREENING"
  end

  # GETTYPES^BGOVHF (BGOVHF.m:126-): active HEALTH FACTORS (#9999999.64),
  # NAME^CATEGORY^^TYPE^IEN^...; each factor names its own category.
  def test_health_factor_types
    factors = listed("9999999.64", ".01;.03").to_h { |e| [ e[:ien].to_s, e[:pieces] ] }
    got = rows("BGOVHF GETTYPES", "1").map { |r| pieces(r) }
    smoker = got.find { |r| r[0] == "CURRENT SMOKER, STATUS UNKNOWN" } || flunk("no CURRENT SMOKER factor: #{got.first(3).inspect}")
    assert_equal "TOBACCO (SMOKING)", smoker[1]
    got.first(40).each do |name, category, _, _, ien|
      on_file = factors[ien] || flunk("#{name} (#{ien}) is not on #9999999.64")
      assert_equal name, on_file[0]
      assert_equal category, factors.dig(on_file[1], 0).to_s, "#{name}'s category"
    end
  end

  # GETTYPES^BGOVPED and GETNAME^BGOVPED (BGOVPED.m:163-): the education
  # topics, NAME^CATEGORY^^^IEN^C(ategory) or E(ntry); a topic's category.
  def test_education_topics
    got = rows("BGOVPED GETTYPES", "0").map { |r| pieces(r) }
    entry_row = got.find { |r| r[5] == "E" && r[4].to_i.positive? } || flunk("no education topic entry")
    assert_equal entry_row[0], entry("9999999.09", entry_row[4], ".01").dig(".01", :external)
    assert(got.any? { |r| r[5] == "C" && r[0] == entry_row[1] }, "#{entry_row[0]}'s category #{entry_row[1]} is listed")
    mental = listed("9999999.09", ".01").find { |e| e[:pieces][0] == "MNTL-LITERATURE" } || flunk("no MNTL-LITERATURE topic")
    assert_equal "MENTAL HEALTH", value("BGOVPED GETNAME", mental[:ien].to_s)
    assert_empty rows("BGOVPED GETNAME", "999999999").reject(&:empty?)
  end

  # GETPL^BGOCC (BGOCC.m:99-): the chief complaint pick list of a type,
  # IEN^NAME^BODY SITE; no type is error -1006.
  def test_chief_complaint_pick_list
    got = rows("BGOCC GETPL", "1").map { |r| pieces(r) }
    refute_empty got
    assert_includes got.map { |r| r[1] }, "Cough"
    got.each { |ien, name| assert_operator ien.to_i, :>, 0, name }
    assert_equal [ "-1006^Type not specified." ], rows("BGOCC GETPL", "")
  end

  # NEXTID^BGOPROB1: the facility prefix and one past the patient's highest
  # problem number (PROBLEM #9000011 .07).
  def test_next_problem_number
    numbers = listed("9000011", ".02;.07").select { |e| e[:pieces][0] == DFN.to_s }.map { |e| e[:pieces][1].to_i }
    prefix, number = value("BGOPROB NEXTID", DFN.to_s).split("-")
    refute_empty prefix.to_s
    assert_equal numbers.max + 1, number.to_i
  end

  # The checks BGOPROB SET's dialog makes on a new problem: CHKASM^BGOASLK
  # (an asthma code), QUALLK^BGOVPOV1 (prompt for a normal/abnormal
  # qualifier), FRAC^BGOVPOV1 (a fracture's healing qualifiers) and
  # INJURY^BGOVPOV2 (an injury code).
  def test_new_problem_checks
    assert_equal "1", value("BGOASLK CHKASM", *ASTHMA)
    assert_equal "0", value("BGOASLK CHKASM", "J11.1", INFLUENZA)
    assert_equal "0", value("BGOVPOV1 QUALLK", INFLUENZA, "N")
    fracture, healing = value("BGOVPOV1 FRAC", FEMUR_FRACTURE).split("^", 2)
    refute_empty fracture.to_s, "a femur fracture asks for healing"
    assert_includes healing.split(";").map { |q| q.split("|").first }, "Nonunion"
    assert_equal "^", value("BGOVPOV1 FRAC", INFLUENZA)
    assert_equal "0", value("BGOVPOV2 INJURY", INFLUENZA, VISIT.to_s)
    assert_equal "-1^Missing SNOMED CT", value("BGOVPOV2 INJURY", "", VISIT.to_s)
  end
end
