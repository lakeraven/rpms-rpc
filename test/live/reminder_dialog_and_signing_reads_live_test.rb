# frozen_string_literal: true

require_relative "live_helper"
require_relative "wire_reads"

# The reminder dialog reads VueCentric makes while a nurse or provider works
# a reminder into a note (PXRM REMINDER DIALOG (TIU), ORQQPXRM REMINDER
# DIALOG, ORQQPXRM DIALOG PROMPTS), and the reads around a new order and its
# signature: the new-order dialogs (ORWPS1 NEWDLG, ORWDCN32 NEWDLG), the
# controlled-substance signing text (ORDEA SIGINFO, ORDEA DEATEXT), the drug
# checks (BEHORXSP GHB, BEHORXF3 TSTASSOC), the print devices for the
# orders (ORWD2 DEVINFO), a delayed order's event (OREVNTX1 GTEVT), an
# asthma problem's classes (BGOPROB GET CLASS) and the anytime-encounters
# parameter (ORWPCE ANYTIME). Sent with the client's parameters from a
# recorded session, as the provider, and checked against the file each reads.
# Read only.
class ReminderDialogAndSigningReadsLiveTest < LiveSpec::Test
  include WireReads

  runs_as :provider

  DFN = 2
  CLINIC = 3 # DEMO IHS CLINIC
  SCREENING_BUNDLE = 747 # IHS-SCREENING BUNDLE 2015, a reminder dialog (#801.41)
  DEPRESSION_SCREEN = 123 # the cover sheet's Depression Screen reminder (#811.9)
  BLOOD_PRESSURE_ELEMENT = 57 # MT BLOOD PRESSURE, a dialog element of the bundle
  ASPIRIN = 1521
  ORDER = 4 # DFN 2's seeded prescription

  # DIALOG^PXRMRPCD (PXRMRPCD.m:54-): the dialog's elements, 1^IEN^SEQUENCE^
  # TYPE^... with their text rows 2^IEN^SEQUENCE^TEXT; each element is a
  # REMINDER DIALOG (#801.41) entry.
  def test_a_reminder_dialog_loads_its_elements
    assert_equal "R", entry("801.41", SCREENING_BUNDLE, "4").dig("4", :internal), "#{SCREENING_BUNDLE} is a reminder dialog"
    got = chart_rows("PXRM REMINDER DIALOG (TIU)", SCREENING_BUNDLE.to_s, DFN.to_s).map { |r| pieces(r) }
    elements = got.select { |r| r[0] == "1" }
    refute_empty elements
    elements.map { |r| r[1] }.uniq.first(30).each { |ien| refute_empty entry("801.41", ien, ".01").dig(".01", :external) }
    bp = got.find { |r| r[0] == "2" && r[1] == BLOOD_PRESSURE_ELEMENT.to_s } || flunk("no text row for element #{BLOOD_PRESSURE_ELEMENT}")
    assert_equal "Blood Pressure:", bp[3]
    assert_equal [ "-1", "dialog ien not specified" ], pieces(chart_rows("PXRM REMINDER DIALOG (TIU)", "0", DFN.to_s).first)
  end

  # PROMPT^ORQQPXRM (PXRMRPCC): an element's prompts; a measurement element
  # asks for its vital, 3^IEN^^MSR^^...^ABBREVIATION.
  def test_a_dialog_elements_prompts
    assert_equal "MT BLOOD PRESSURE", entry("801.41", BLOOD_PRESSURE_ELEMENT, ".01").dig(".01", :external)
    got = rows("ORQQPXRM DIALOG PROMPTS", BLOOD_PRESSURE_ELEMENT.to_s, "0", "").map { |r| pieces(r) }
    measurement = got.find { |r| r[0] == "3" && r[3] == "MSR" } || flunk("no MSR prompt: #{got.inspect}")
    assert_equal [ BLOOD_PRESSURE_ELEMENT.to_s, "BP" ], measurement.values_at(1, 7)
  end

  # DIALOG^ORQQPXRM (ORQQPXRM.m:19-): the reminder's own dialog (#811.9
  # field 51), for the patient.
  def test_a_reminders_dialog
    dialog = entry("811.9", DEPRESSION_SCREEN, "51").dig("51", :internal)
    refute_empty dialog.to_s, "the Depression Screen reminder has a dialog"
    got = rows("ORQQPXRM REMINDER DIALOG", DEPRESSION_SCREEN.to_s, DFN.to_s).map { |r| pieces(r) }
    elements = got.select { |r| r[0] == "1" }.map { |r| r[1] }.uniq
    refute_empty elements
    elements.each { |ien| refute_empty entry("801.41", ien, ".01").dig(".01", :external), "element #{ien}" }
  end

  # NEWDLG^ORWPS1 (ORWPS1.m:5-) and NEWDLG^ORWDCN32 (ORWDCN32.m:98-): the
  # dialog a new medication or consult opens, IEN;FORM;GROUP;TYPE^TEXT, from
  # ORWDX NEW MED and ORWDX NEW CONSULT; each matches its #101.41 entry.
  def test_the_dialogs_a_new_order_opens
    { "ORWPS1 NEWDLG" => [ "o" ], "ORWDCN32 NEWDLG" => [ "C", CLINIC.to_s ] }.each do |rpc, params|
      ids, text = pieces(value(rpc, *params))
      ien, form, group, type = ids.split(";")
      filed = entry("101.41", ien, ".01;4;5")
      assert_equal [ filed.dig("5", :internal), filed.dig("4", :internal) ], [ group, type ], "#{rpc}: dialog #{ien}"
      assert_equal value("ORWDXM FORMID", ien), form, "#{rpc}: the dialog's form"
      refute_empty text
    end
    assert_equal "PSO OERR", entry("101.41", pieces(value("ORWPS1 NEWDLG", "o"))[0].to_i, ".01").dig(".01", :external)
  end

  # SIGINFO^ORDEA (ORDEA.m:52-): what a controlled-substance signature
  # shows: the patient, today, the provider, the facility's address and the
  # provider's DEA number (NEW PERSON 53.2). DEATEXT: the legal text.
  def test_controlled_substance_signing_text
    got = chart_rows("ORDEA SIGINFO", DFN.to_s, client.duz.to_s)
    assert_equal entry("2", DFN, ".01").dig(".01", :external), got[0]
    assert_match(/\ADate of Issuance: \w{3} \d{2}, \d{4}\z/, got[1])
    assert_equal "Provider: PROFILE,MD", got[2]
    dea = entry("200", client.duz, "53.2").dig("53.2", :external)
    assert_equal "DEA: #{dea}", got.last
    text = chart_rows("ORDEA DEATEXT").join(" ")
    assert_includes text, "two-factor authentication"
  end

  # GHB^BEHORXSP and TSTASSOC^BEHORXF3: aspirin is no sodium oxybate and has
  # no associated lab test.
  def test_drug_checks_on_aspirin
    assert_equal "0", value("BEHORXSP GHB", ASPIRIN.to_s)
    assert_equal "0", value("BEHORXF3 TSTASSOC", ASPIRIN.to_s)
  end

  # DEVINFO^ORWD2: the print devices for the orders being signed, a header
  # of the location's defaults, then ID^...^PRINT CHART COPY per order.
  def test_print_devices_for_the_orders
    got = rows("ORWD2 DEVINFO", CLINIC.to_s, "E", { "1" => "#{ORDER};2^RS" })
    assert_equal 2, got.size, got.inspect
    assert_equal "#{ORDER};2", pieces(got[1])[0]
  end

  # GTEVT^OREVNTX1 (OREVNTX1.m:9-): a patient event's TYPE^ID^NAME^DISPLAY;
  # the event is an OE/RR RELEASE EVENTS (#100.5) entry, TYPE field 2.
  def test_a_delayed_orders_event
    type, id, name = pieces(value("OREVNTX1 GTEVT", "1"))
    filed = entry("100.5", id, ".01;2")
    assert_equal [ filed.dig(".01", :external), filed.dig("2", :internal) ], [ name, type ]
    assert_empty rows("OREVNTX1 GTEVT", "").reject(&:empty?)
  end

  # GET CLASS (DICLASS^BGOASLK): an asthma problem's severity classes.
  def test_asthma_severity_classes
    got = rows("BGOPROB GET CLASS", "J45.909^195967001^ASTHMA SEVERITY").map { |r| pieces(r) }
    assert_equal [ %w[1 INTERMITTENT], [ "2", "MILD PERSISTENT" ], [ "3", "MODERATE PERSISTENT" ], [ "4", "SEVERE PERSISTENT" ] ], got
  end

  # ANYTIME^ORWPCE2 (ORWPCE2.m:132-): the ORWPCE ANYTIME ENCOUNTERS
  # parameter for the user, 1 when set.
  def test_anytime_encounters_parameter
    set = rows("ORWU PARAM", "ORWPCE ANYTIME ENCOUNTERS").first.to_s
    got = rows("ORWPCE ANYTIME").reject(&:empty?)
    assert_equal (set.to_i.positive? ? [ "1" ] : [ set ].reject(&:empty?)), got, "the parameter is #{set.inspect}"
  end
end

# PXRM REMINDER DIALOG (TIU) and the ORDEA reads are registered in OR CPRS GUI
# CHART: sent under it, the nurse and the medical assistant are refused them.
class ReminderDialogAndSigningRefusalLiveTest < LiveSpec::Test
  include WireReads

  runs_as :nurse, :medical_assistant

  def test_each_is_refused_without_the_chart_option
    refute role_row.holds?(CPRS_CHART), "#{role}'s row holds #{CPRS_CHART}: this spec no longer describes it"
    assert_chart_refused("PXRM REMINDER DIALOG (TIU)", "747", "2")
    assert_chart_refused("ORDEA SIGINFO", "2", "206")
    assert_chart_refused("ORDEA DEATEXT")
  end
end
