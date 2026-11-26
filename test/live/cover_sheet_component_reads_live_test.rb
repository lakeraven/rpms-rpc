# frozen_string_literal: true

require_relative "live_helper"
require_relative "wire_reads"
require "rpms_rpc/api/allergy"

# VueCentric's Cover Sheet components and the detail each opens, for a
# patient with problems, a prescription, an allergy, a consult, a lab order,
# reminders and vitals (DFN 2 on the demo build): allergies (BEHOARCV LIST,
# DETAIL; BEHOCACV DETAIL; BEHOART LOAD), medications (BEHORXCV LIST, DETAIL),
# reminders (BEHORMCV LIST, DETAIL), consults (BEHOCNCV LIST, DETAIL), a lab
# order's results (BEHOLRCV DETAIL), a problem (BEHOPLCV DETAIL), a visit
# (BEHOENCV DETAIL), vitals (BEHOVM DETAIL, BEHOVM HELP, BEHOVM2 GETCATS), the
# designated providers (BEHOPTPC DETAIL), record flags (BEHOCACV PRF) and the
# patient inquiry (BEHOPTCX PTINQ). Each list is checked against the file it
# reads, and each detail against its list's row. Read only: BEHOART LOAD is
# sent with its no-lock flag.
class CoverSheetComponentReadsLiveTest < LiveSpec::Test
  include WireReads

  runs_as :provider
  proves "S-SGN-03.1"

  DFN = 2
  NO_PATIENT = 999_999_999

  # LIST^BEHOARCV (BEHOARCV.m:5-): IEN^AGENT^^SIGNS^...^SEVERITY... per
  # PATIENT ALLERGIES (#120.8) entry; DETAIL^BEHOARCV names the agent and its
  # signs; BEHOCACV DETAIL is the CWAD popup of the same entries.
  def test_allergies_on_the_cover_sheet_and_their_detail
    filed = listed("120.8", ".01;.02").select { |e| e[:pieces][0] == DFN.to_s }
    got = rows("BEHOARCV LIST", DFN.to_s, "1").map { |r| pieces(r) }
    assert_equal filed.map { |e| [ e[:ien].to_s, e[:pieces][1] ] }.sort, got.map { |r| r[0, 2] }.sort
    allergy = got.find { |r| r[1] == "PENICILLIN" } || flunk("DFN #{DFN}'s PENICILLIN is not on the cover sheet")
    assert_equal "HIVES", allergy[3]

    detail = rows("BEHOARCV DETAIL", DFN.to_s, allergy[0])
    assert_includes detail, "Causative agent:    PENICILLIN"
    assert_includes detail, "Signs/symptoms:     HIVES"
    popup = rows("BEHOCACV DETAIL", DFN.to_s)
    assert(popup.any? { |l| l.start_with?("PENICILLIN") }, popup.inspect)
    assert_includes popup.map(&:strip), "Signs/symptoms:   HIVES"
    assert_equal [ "^No Allergy Assessment" ], rows("BEHOARCV LIST", NO_PATIENT.to_s, "1")
  end

  # LOAD^BEHOART (BEHOART.m:65-): the entry for the allergy dialog, FIELD^
  # VALUE rows; field 2 is the agent and its file, 3 the type.
  def test_one_allergy_loads_for_the_dialog_without_a_lock
    allergy = listed("120.8", ".01;.02;3.1").find { |e| e[:pieces][0] == DFN.to_s } || flunk("DFN #{DFN} has no #120.8 entry")
    got = rows("BEHOART LOAD", allergy[:ien].to_s, "1").to_h { |r| [ pieces(r)[0], pieces(r)[1..] ] }
    assert_equal allergy[:pieces][1], got.fetch("2")[1], "the agent"
    assert_equal allergy[:pieces][2], got.fetch("3")[0], "the type"
    assert_equal [ "-1^This entry no longer exists." ], rows("BEHOART LOAD", NO_PATIENT.to_s, "1")
  end

  # LIST^BEHORXCV (BEHORXCV.m:6-): the patient's prescriptions (OCL^PSOORRL),
  # ID;TYPE^DRUG^...^ORDER^STATUS^...; DETAIL names the prescriber and the
  # sig. The active one is ORDER #100 entry 4, the seeded aspirin.
  def test_medications_on_the_cover_sheet_and_their_detail
    got = rows("BEHORXCV LIST", DFN.to_s).map { |r| pieces(r) }
    active = got.find { |r| r[8] == "ACTIVE" } || flunk("no active medication for DFN #{DFN}: #{got.inspect}")
    assert_equal "ASPIRIN", active[1]
    assert_equal "#{DFN};DPT(", entry("100", active[7], ".02").dig(".02", :internal), "order #{active[7]} is the patient's"
    detail = rows("BEHORXCV DETAIL", DFN.to_s, active[0])
    assert_equal "ASPIRIN", detail.first
    assert_includes detail, "Prescriber:         PROFILE,MD"
    assert(detail.any? { |l| l.match?(/\ARefills Remaining:\s+3\z/) }, detail.inspect)
    assert_empty rows("BEHORXCV LIST", NO_PATIENT.to_s).reject(&:empty?)
  end

  # LIST^BEHORMCV (BEHORMCV.m:6-): IEN^NAME^DUE^LAST for the cover sheet's
  # reminders (#811.9); DETAIL runs the reminder for the patient.
  def test_reminders_on_the_cover_sheet_and_their_detail
    got = rows("BEHORMCV LIST", DFN.to_s, "0").map { |r| pieces(r) }
    refute_empty got
    got.each do |ien, name, due|
      assert_equal name, entry("811.9", ien, "1.2").dig("1.2", :external), "reminder #{ien}'s print name"
      assert_match(%r{\A(DUE NOW|DUE SOON|RESOLVED|N/A|ERROR|CNBD|\d\d/\d\d/\d{4})?\z}, due.strip, "#{name}'s due status")
    end
    depression = got.find { |r| r[1] == "Depression Screen" } || flunk("no Depression Screen reminder: #{got.inspect}")
    detail = rows("BEHORMCV DETAIL", DFN.to_s, depression[0])
    assert(detail.any? { |l| l.include?("REMINDER DUE") || l.include?("RESOLVED") }, detail.first(8).inspect)
  end

  # LIST^BEHOCNCV (BEHOCNCV.m:6-): IEN^SERVICE^DATE^STATUS^FM DATE per
  # REQUEST/CONSULTATION (#123) entry; DETAIL is ORQQCN DETAIL's text.
  def test_consults_on_the_cover_sheet_and_their_detail
    filed = listed("123", ".02;1").select { |e| e[:pieces][0] == DFN.to_s }
    got = rows("BEHOCNCV LIST", DFN.to_s).map { |r| pieces(r) }
    assert_equal filed.map { |e| e[:ien].to_s }.sort, got.map(&:first).sort
    consult = got.first
    assert_equal entry("123.5", filed.first[:pieces][1], ".01").dig(".01", :external), consult[1]
    assert_equal rows("ORQQCN DETAIL", consult[0]), rows("BEHOCNCV DETAIL", DFN.to_s, consult[0])
  end

  # DETAIL^BEHOLRCV (BEHOLRCV.m:9-): an order's results display
  # (ORDERS^ORCXPND1) for an order BEHOLRCV LIST names.
  def test_lab_order_results_detail
    order = pieces(rows("BEHOLRCV LIST", DFN.to_s).first)
    ien = order[0].to_i
    assert_equal "#{DFN};DPT(", entry("100", ien, ".02").dig(".02", :internal)
    detail = rows("BEHOLRCV DETAIL", DFN.to_s, order[0], ien.to_s)
    refute_empty detail
    assert(detail.first.start_with?(order[1].split(" WC ").first), "the detail opens with the order: #{detail.first.inspect} for #{order[1].inspect}")
  end

  # DETAIL^BEHOPLCV: one problem's display, its ID, narrative and status as
  # PROBLEM (#9000011) holds them.
  def test_problem_detail
    problem = listed("9000011", ".02;.07;.12").find { |e| e[:pieces][0] == DFN.to_s } || flunk("DFN #{DFN} has no problem")
    detail = rows("BEHOPLCV DETAIL", DFN.to_s, problem[:ien].to_s)
    assert_includes detail.map(&:strip), "PROBLEM DATA"
    assert(detail.any? { |l| l.match?(/\A\s+ID:\s+#{problem[:pieces][1]}\z/) }, "the facility's problem ID: #{detail.first(5).inspect}")
    assert(detail.any? { |l| l.include?("Problem:") && l.include?("TYPE 2 DIABETES MELLITUS") }, detail.first(5).inspect)
  end

  # DETAIL^BEHOENCV: the visit report (GETRPT^BEHOENPS) for one of the
  # patient's visits, naming its IEN and date.
  def test_visit_detail
    visit = pieces(rows("BEHOENCV LIST", DFN.to_s).last)[0]
    ien = visit.split(";").last
    detail = rows("BEHOENCV DETAIL", DFN.to_s, visit)
    assert_includes detail.map(&:strip), "VISIT IEN:  #{ien}"
    shown = entry("9000010", ien, ".01").dig(".01", :external)
    assert(detail.any? { |l| l.include?("VISIT/ADMIT DATE&TIME: #{shown}") }, "the visit's date, #{shown}")
  end

  # DETAIL^BEHOVM (BEHOVM.m:70-): the patient's vitals by date; HELP: a
  # vital's help text from BEH MEASUREMENT CONTROL (#90460.01); GETCATS^
  # BEHOVM2 (BEHOVM2.m:70-): a vital's qualifier categories.
  def test_vitals_detail_help_and_qualifiers
    detail = rows("BEHOVM DETAIL", DFN.to_s)
    assert(detail.any? { |l| l.match?(/\A\s+BLOOD PRESSURE\s+142\/88 mmHg/) }, "the seeded blood pressure: #{detail.first(8).inspect}")
    assert(detail.any? { |l| l.include?("Location: DEMO PRIMARY CARE") })
    assert_equal [ "No help is available for this item." ], rows("BEHOVM HELP", "BP"), "no help text is seeded"
    cats = rows("BEHOVM2 GETCATS", "BP").map { |r| pieces(r) }
    method = cats.find { |c| c[1] == "METHOD" } || flunk("BP has no METHOD qualifiers: #{cats.inspect}")
    assert_includes method[2].split("~"), "CUFF"
    assert_equal [ "No vital in BEH MEASUREMENT CONTROL FILE" ], rows("BEHOVM2 GETCATS", "NO SUCH VITAL")
  end

  # DETAIL^BEHOPTPC, PRF^BEHOCACV and PTINQ^BEHOPTCX: the designated
  # providers (none seeded), the record flags (none active) and the patient
  # inquiry report, which names the patient and the facility's chart number.
  def test_designated_providers_flags_and_inquiry
    designated = rows("BEHOPTPC DETAIL", DFN.to_s)
    assert_includes designated, "**--NO EXISTING DESIGNATED PROVIDERS--**"
    flags = listed("26.13", ".01;.03").select { |e| e[:pieces][0] == DFN.to_s && e[:pieces][1] == "1" }
    assert_empty flags, "DFN #{DFN} has no active record flag"
    assert_empty rows("BEHOCACV PRF", DFN.to_s).reject(&:empty?)
    name = entry("2", DFN, ".01").dig(".01", :external)
    inquiry = rows("BEHOPTCX PTINQ", DFN.to_s)
    assert(inquiry.any? { |l| l.start_with?("PATIENT: #{name}") }, inquiry.first(8).inspect)
  end
end

# HASESIG^BEHOUSCX (BEHOUSCX.m:117-119): whether the user has an electronic
# signature code, as each role's row says it does.
class CoverSheetSignatureCodeLiveTest < LiveSpec::Test
  include WireReads

  runs_as :provider, :nurse, :front_desk_clerk, :scheduler

  def test_has_an_electronic_signature_code_as_the_row_says
    assert_equal (role_row.esig ? "1" : "0"), value("BEHOUSCX HASESIG")
  end
end
