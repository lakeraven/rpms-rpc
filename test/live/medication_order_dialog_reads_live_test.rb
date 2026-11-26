# frozen_string_literal: true

require_relative "live_helper"
require_relative "wire_reads"

# The reads VueCentric's outpatient medication dialog makes while a provider
# writes a prescription, sent with the parameters the client sends in a
# recorded session (aspirin, orderable item 1521, dispense drug 32): the
# item's defaults (ORWDPS2 OISLCT, ORWDPS1 ODSLCT), the schedules (ORWDPS1
# SCHALL, ORWDPS32 VALSCH), quantity and days supply (ORWDPS2 DAY2QTY,
# ORWDPS1 DFLTSPLY, ORWDPS32 VALQTY), refills (ORWDPS2 MAXREF), the
# prescriber checks (ORWDPS32 AUTH, ORWDPS1 FAILDEA, ORWOR PKIUSE, ORWOR
# PKISITE), the drug's message (ORWDPS32 DRUGMSG), whether the item may be
# ordered (ORWDXA ISACTOI), a quick order's responses (ORWDXM1 BLDQRSP), an
# order's text (ORWORR GETTXT), the consult dialog's defaults (ORWDCN32 DEF)
# and the encounter checks the dialog runs around them (ORWPCE VISIT,
# ORWPCE HASCPT, ORWPCE GET SET OF CODES, ORWCIRN FACLIST, ORWPFSS IS PFSS
# ACTIVE?). Each is checked against the file it reads or the routine's rule.
# Read only.
class MedicationOrderDialogReadsLiveTest < LiveSpec::Test
  include WireReads

  runs_as :provider

  DFN = 2 # the demo patient with the seeded aspirin prescription
  CLINIC = 3 # DEMO IHS CLINIC
  ASPIRIN = 1521 # ASPIRIN TAB,SA on ORDERABLE ITEMS (#101.43)
  ASPIRIN_DRUG = 32 # its dispense drug on DRUG (#50)
  ORDER = 4 # DFN 2's seeded prescription
  PSO_OERR = 147 # the outpatient medication dialog

  # OISLCT^ORWDPS2 (ORWDPS2.m:7-): the item's defaults in ~SECTION blocks;
  # the medication is the item itself and each dose names its drug.
  def test_orderable_item_defaults
    got = rows("ORWDPS2 OISLCT", ASPIRIN.to_s, "O", DFN.to_s, "Y", "N")
    item = entry("101.43", ASPIRIN, ".01")
    sections = got.select { |r| r.start_with?("~") }
    assert_equal "~Medication", got.first
    medication = pieces(got[1])
    assert_equal [ "d#{ASPIRIN}", item.dig(".01", :external).strip ], [ medication[0], medication[1].strip ], "the item's own name"
    assert_includes sections, "~AllDoses"
    assert_includes sections, "~Dispense"
    dose = got[got.index("~AllDoses") + 1]
    assert_equal ASPIRIN_DRUG.to_s, pieces(dose)[1], "800MG is dispense drug #{ASPIRIN_DRUG}"
    drug = got[got.index("~Dispense") + 1]
    assert_equal "i#{ASPIRIN_DRUG}", pieces(drug)[0]
  end

  # ODSLCT^ORWDPS1 (ORWDPS1.m:5-): the outpatient dialog's lists, each under
  # its ~SECTION: priorities (ORDER URGENCY, #101.42), refills, pickup.
  def test_outpatient_dialog_lists
    got = rows("ORWDPS1 ODSLCT", "O", DFN.to_s, CLINIC.to_s)
    assert_equal "~Priority", got.first
    [ "~DispMsg", "~Refills", "~Pickup" ].each { |s| assert_includes got, s }
    urgencies = listed("101.42", ".01").to_h { |e| [ e[:ien].to_s, e[:pieces][0] ] }
    priorities = got[1...got.index("~DispMsg")].select { |r| r.start_with?("i") }.map { |r| pieces(r.delete_prefix("i")) }
    assert_includes priorities, [ "9", "ROUTINE" ]
    priorities.each { |ien, name| assert_equal urgencies[ien], name, "urgency #{ien}" }
  end

  # SCHALL^ORWDPS1 (ORWDPS1.m:101-): ADMINISTRATION SCHEDULE (#51.1) entries,
  # NAME^...; VALSCH^ORWDPS33 (ORWDPS33.m:143-): a schedule the pharmacy
  # accepts. An inpatient schedule must be on file; outpatient takes free text.
  def test_schedules
    names = listed("51.1", ".01").map { |e| e[:pieces][0] }
    got = rows("ORWDPS1 SCHALL", DFN.to_s, "0").map { |r| pieces(r)[0] }
    refute_empty got
    got.each { |name| assert_includes names, name }
    assert_equal "1", value("ORWDPS32 VALSCH", "Q2H", "I")
    assert_equal "0", value("ORWDPS32 VALSCH", "NOT A SCHEDULE", "I"), "an inpatient schedule not on #51.1"
    assert_equal "1", value("ORWDPS32 VALSCH", "DAILY", "O")
  end

  # DAY2QTY^ORWDPS2 (ORWDPS2.m:147-) and DFLTSPLY^ORWDPS1 (ORWDPS1.m:70-):
  # the quantity for a days supply, and the default days supply; VALQTY
  # (ORWDPS33.m:125-): a quantity is a positive number.
  def test_quantity_and_days_supply
    assert_equal "360", value("ORWDPS2 DAY2QTY", "30", "1^", "Q2H^", "~^", DFN.to_s, ASPIRIN_DRUG.to_s), "1 tab every 2 hours for 30 days"
    days = value("ORWDPS1 DFLTSPLY", "1^", "Q2H^", DFN.to_s, ASPIRIN_DRUG.to_s, ASPIRIN.to_s)
    assert_operator days.to_i, :>, 0
    assert_operator days.to_i, :<=, value("ORWU PARAM", "BEHORX MAX DAYS SUPPLY").to_i
    assert_equal "1", value("ORWDPS32 VALQTY", "90")
    assert_equal "0", value("ORWDPS32 VALQTY", "ABC")
  end

  # MAXREF^ORWDPS2 (ORWDPS2.m:181-) through EN^PSOSIGMX: the IHS refill rule
  # for a drug that is no controlled substance, 3 for a 90-day supply and at
  # most 15 under 60 days.
  def test_maximum_refills_follow_the_days_supply
    assert_equal "3", value("ORWDPS2 MAXREF", DFN.to_s, ASPIRIN_DRUG.to_s, "90", ASPIRIN.to_s, "0")
    thirty = value("ORWDPS2 MAXREF", DFN.to_s, ASPIRIN_DRUG.to_s, "30", ASPIRIN.to_s, "0").to_i
    assert_operator thirty, :>, 3
    assert_operator thirty, :<=, 15
  end

  # AUTH^ORWDPS32 (ORWDPS32.m:201-): 0 when the prescriber is authorized
  # (NEW PERSON 53.1); FAILDEA^ORWDPS1: 0 when no DEA check fails;
  # PKIUSE^ORWOR: whether the user has a digital-signature certificate.
  def test_prescriber_checks
    authorized = entry("200", client.duz, "53.1").dig("53.1", :internal)
    assert_equal "1", authorized, "PROFILE,MD is authorized to write medication orders"
    assert_equal "0", value("ORWDPS32 AUTH", client.duz.to_s)
    assert_equal "1^", value("ORWDPS32 AUTH", "2")[0, 2], "USER,TEST is not authorized"
    assert_equal "0", value("ORWDPS1 FAILDEA", ASPIRIN.to_s, client.duz.to_s, "O"), "aspirin needs no DEA number"
    assert_equal "0", value("ORWOR PKIUSE", client.duz.to_s)
    assert_includes %w[0 1], value("ORWOR PKISITE")
  end

  # DRUGMSG^ORWDPS33 (ORWDPS33.m:28-31): MESSAGE^QUICK CODE of the drug;
  # ISACTOI^ORWDXA (ORWDXA.m:267-): nothing for an active item.
  def test_drug_message_and_active_item
    assert_equal "^", value("ORWDPS32 DRUGMSG", ASPIRIN_DRUG.to_s), "the seeded drug carries no message"
    inactive = entry("101.43", ASPIRIN, ".1").dig(".1", :internal).to_s
    assert_empty inactive, "aspirin has no inactive date"
    assert_empty rows("ORWDXA ISACTOI", ASPIRIN.to_s).reject(&:empty?)
  end

  # BLDQRSP^ORWDXM1 (ORWDXM1.m:5-): QUICK LEVEL^RESPONSE ID^DIALOG^TYPE^
  # FORM ID^DISPLAY GROUP for the outpatient dialog itself.
  def test_quick_order_responses_for_the_dialog
    level, _response, dialog, type, form, group = pieces(rows("ORWDXM1 BLDQRSP", PSO_OERR.to_s, "#{DFN}^#{CLINIC}^#{client.duz}^0^F^25^0;C;0;0^0^^^", "0", CLINIC.to_s).first)
    filed = entry("101.41", PSO_OERR, "4;5")
    assert_equal "0", level, "a dialog, not a quick order"
    assert_equal PSO_OERR.to_s, dialog
    assert_equal filed.dig("4", :internal), type
    assert_equal value("ORWDXM FORMID", PSO_OERR.to_s), form
    assert_equal filed.dig("5", :internal), group
  end

  # GETTXT^ORWORR (ORWORR.m:214-): the order's text (TEXT^ORQ12).
  def test_order_text
    got = rows("ORWORR GETTXT", ORDER.to_s)
    assert_equal "ASPIRIN TAB,SA", got.first.strip
    assert_includes got, "Quantity: 30 TAB Days: 30 Refills: 3"
    assert_equal got, rows("ORWORR GETTXT", "#{ORDER};1"), "an order with no action is its first"
  end

  # DEF^ORWDCN32: the consult dialog's lists; each urgency is an ORDER
  # URGENCY (#101.42) entry.
  def test_consult_dialog_defaults
    got = rows("ORWDCN32 DEF", "C")
    urgencies = listed("101.42", ".01").to_h { |e| [ e[:ien].to_s, e[:pieces][0] ] }
    assert_includes got, "~Inpt Cslt Urgencies"
    assert_includes got, "~Outpt Urgencies"
    outpatient = got[(got.index("~Outpt Urgencies") + 1)..].take_while { |r| !r.start_with?("~") }
    picks = outpatient.select { |r| r.start_with?("i") }.map { |r| pieces(r.delete_prefix("i")) }
    refute_empty picks
    picks.each { |ien, name| assert_equal urgencies[ien], name, "urgency #{ien}" }
  end

  # The encounter checks: VISIT^ORWPCE (visit types for a clinic's encounter
  # form, none on the demo build), HASCPT^ORWPCE2 (are the items mapped to a
  # CPT on #811.1), GETSET^ORWPCE2 (a field's set of codes), FACLIST^ORWCIRN
  # (remote facilities; the MPI is not installed) and PFSSACTV^ORWPFSS.
  def test_encounter_checks_the_dialog_runs
    assert_equal "0", value("ORWPCE VISIT", CLINIC.to_s)
    items = { "1" => "5849;AUTTEDT(", "2" => "188;AUTTHF(" }
    assert_equal [ "5849;AUTTEDT(=0", "188;AUTTHF(=0" ], rows("ORWPCE HASCPT", items), "no CPT is mapped to either"
    got = rows("ORWPCE GET SET OF CODES", "9000010.16", ".06").map { |r| pieces(r) }
    assert_includes got, %w[3 Good]
    assert_equal rows("BGOUTL3 GETSET", "9000010.16", ".06"), got.map { |r| r.join("^") }, "the same data dictionary as BGOUTL3 GETSET"
    assert_equal "-1^CIRN MPI not installed.", value("ORWCIRN FACLIST", DFN.to_s)
    assert_equal "0", value("ORWPFSS IS PFSS ACTIVE?")
  end
end
