# frozen_string_literal: true

require_relative "live_helper"
require_relative "wire_reads"

# The order reads VueCentric makes while it opens a medication order dialog,
# each checked against the file it reads: display groups (ORWDX DGNM), order
# dialogs and their forms (OREVNTX1 DLGIEN, ORWDXM FORMID), the quick-order
# tests (ORWDXM3 ISUDQO, ORIMO ISIVQO, ORWDPS2 QOGRP), one order's fields
# (ORWORR GETBYIFN), the controlled-substance check (ORDEA CSVALUE), the
# non-VA medication reasons (ORWPS REASON) and the days-supply limit
# (BEHORXF4 MAXDAYS). Parameters are the client's, from a recorded session.
# Read only.
class OrderDialogReadsLiveTest < LiveSpec::Test
  include WireReads

  runs_as :provider

  ORDER = 4 # DFN 2's seeded outpatient prescription, ASPIRIN TAB,SA 800MG
  NO_ORDER = 999_999_999

  # DGNM^ORWDX (ORWDX.m:202-204): the B index of DISPLAY GROUP (#100.98),
  # which holds both the NAME and the SHORT NAME; the client sends the short
  # name ("UD RX", "O RX").
  def test_display_group_by_name_is_its_entry
    groups = listed("100.98", ".01;3")
    [ "UD RX", "O RX" ].each do |short|
      group = groups.find { |g| g[:pieces][1] == short } || flunk("no #100.98 entry with short name #{short}")
      assert_equal group[:ien].to_s, value("ORWDX DGNM", short), "#{short} is #100.98 #{group[:ien]}"
      assert_equal group[:ien].to_s, value("ORWDX DGNM", group[:pieces][0]), "#{group[:pieces][0]} is #100.98 #{group[:ien]}"
    end
    assert_empty rows("ORWDX DGNM", "NO SUCH GROUP").reject(&:empty?)
  end

  # DLGIEN^OREVNTX1 (OREVNTX1.m:297-300): the B index of ORDER DIALOG (#101.41).
  def test_dialog_by_name_is_its_entry
    [ "PSJ OR PAT OE", "PSO OERR" ].each do |name|
      ien = value("OREVNTX1 DLGIEN", name)
      assert_equal name, entry("101.41", ien, ".01").dig(".01", :external)
    end
    assert_empty rows("OREVNTX1 DLGIEN", "NO SUCH DIALOG").reject(&:empty?)
  end

  # ISUDQO^ORWDXM3 (ORWDXM3.m:150-158), ISIVQO^ORIMO and QOGRP^ORWDPS2
  # (ORWDPS2.m:230): a quick order (#101.41 TYPE Q) is unit dose when its
  # display group is UD RX, IV when IV RX; QOGRP also takes the inpatient and
  # clinic medication groups. Each is checked against the dialog's own TYPE
  # and DISPLAY GROUP.
  def test_quick_order_kind_follows_its_display_group
    groups = listed("100.98", ".01;3").to_h { |g| [ g[:pieces][1], g[:ien].to_s ] }
    dialogs = listed("101.41", ".01;4;5")
    unit_dose = dialogs.find { |d| d[:pieces][1] == "Q" && d[:pieces][2] == groups.fetch("UD RX") } || flunk("no unit dose quick order on #101.41")
    outpatient = dialogs.find { |d| d[:pieces][1] == "Q" && d[:pieces][2] == groups.fetch("O RX") } || flunk("no outpatient quick order on #101.41")
    dialog = dialogs.find { |d| d[:pieces][0] == "PSJ OR PAT OE" } || flunk("no PSJ OR PAT OE dialog")

    assert_equal "1", value("ORWDXM3 ISUDQO", unit_dose[:ien].to_s), "#{unit_dose[:pieces][0]} is a UD RX quick order"
    assert_equal "0", value("ORWDXM3 ISUDQO", outpatient[:ien].to_s), "#{outpatient[:pieces][0]} is an O RX one"
    assert_equal "0", value("ORWDXM3 ISUDQO", dialog[:ien].to_s), "a dialog (TYPE D) is no quick order"
    assert_equal "1", value("ORWDPS2 QOGRP", unit_dose[:ien].to_s)
    assert_equal "0", value("ORWDPS2 QOGRP", outpatient[:ien].to_s)
    iv = groups["IV RX"]
    iv_order = iv && dialogs.find { |d| d[:pieces][1] == "Q" && d[:pieces][2] == iv }
    assert_equal "0", value("ORIMO ISIVQO", unit_dose[:ien].to_s)
    assert_equal "1", value("ORIMO ISIVQO", iv_order[:ien].to_s) if iv_order
  end

  # FORMID^ORWDXM (ORWDXM.m:68-74): a dialog's form; a quick order with no
  # form of its own takes its display group's default dialog's.
  def test_a_quick_order_shares_its_groups_dialog_form
    unit_dose_dialog = value("OREVNTX1 DLGIEN", "PSJ OR PAT OE")
    form = value("ORWDXM FORMID", unit_dose_dialog)
    assert_operator form.to_i, :>, 0
    refute_equal form, value("ORWDXM FORMID", value("OREVNTX1 DLGIEN", "PSO OERR")), "inpatient and outpatient medications are different forms"
    groups = listed("100.98", ".01;3").to_h { |g| [ g[:pieces][1], g[:ien].to_s ] }
    quick = listed("101.41", ".01;4;5").find { |d| d[:pieces][1] == "Q" && d[:pieces][2] == groups.fetch("UD RX") } || flunk("no unit dose quick order")
    assert_equal form, value("ORWDXM FORMID", quick[:ien].to_s), "#{quick[:pieces][0]} opens the unit dose form"
  end

  # GETBYIFN^ORWORR (ORWORR.m:129): ~IFN;ACTION^GROUP^ENTERED^START^STOP^
  # STATUS^...^PROVIDER^PROVIDER NAME..., then the order text, each row
  # prefixed t. Checked against ORDER (#100).
  def test_one_order_reads_back_against_the_order_file
    got = rows("ORWORR GETBYIFN", ORDER.to_s)
    head = pieces(got.first)
    filed = entry("100", ORDER, "1;5;23")
    assert_match(/\A~#{ORDER};\d+\z/, head[0])
    assert_equal filed.dig("23", :internal), head[1], "piece 2 is DISPLAY GROUP"
    assert_equal filed.dig("5", :internal), head[5], "piece 6 is STATUS"
    assert_equal [ filed.dig("1", :internal), filed.dig("1", :external) ], head.values_at(9, 10), "pieces 10-11 are the provider"
    text = got.drop(1).map { |r| r.delete_prefix("t") }.join(" ")
    assert_includes text, "ASPIRIN TAB,SA", "DFN 2's seeded prescription"
    assert_match(/Quantity: 30 TAB Days: 30 Refills: 3/, text)

    stub = rows("ORWORR GETBYIFN", NO_ORDER.to_s)
    assert_equal "~#{NO_ORDER};1", pieces(stub.first)[0]
    assert pieces(stub.first)[1..11].all?(&:empty?), "an order not on file reads as an empty row: #{stub.inspect}"
  end

  # CSVALUE^ORDEA (ORDEA.m:13-25): 1 for a controlled substance. Aspirin is
  # not one.
  def test_aspirin_is_not_a_controlled_substance
    assert_equal "0", value("ORDEA CSVALUE", "#{ORDER};1")
    assert_equal "0", value("ORDEA CSVALUE", NO_ORDER.to_s), "an order not on file has no drug to check"
  end

  # REASON^ORWPS (ORWPS.m:161-164): the ORWD NONVA REASON list, N^text.
  def test_non_va_medication_reasons_are_the_parameters_list
    got = rows("ORWPS REASON").map { |r| pieces(r) }
    refute_empty got
    assert_equal (1..got.size).map(&:to_s), got.map(&:first), "numbered in order"
    assert_equal value("ORWU PARAM", "ORWD NONVA REASON"), got.first[1], "the parameter's first instance"
    assert_includes got.map { |r| r[1] }, "Medication prescribed by another provider."
  end

  # MAXDAYS^BEHORXF4 (BEHORXF4.m:34-45): BEHORX MAX DAYS SUPPLY for a drug
  # that is no controlled substance.
  def test_max_days_supply_is_the_sites_parameter
    expected = value("ORWU PARAM", "BEHORX MAX DAYS SUPPLY")
    assert_operator expected.to_i, :>, 0
    assert_equal expected, value("BEHORXF4 MAXDAYS", "1521"), "the orderable item the client sent"
  end
end
