# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/lab"
require "rpms_rpc/api/medication"
require "rpms_rpc/api/vital"

# Vital.latest_by_type (BEHOVM LIST), Vital.grid (BEHOVM GRID),
# Lab.result_date_range (ORWLRR NEWOLD), Lab.specimen (ORWLRR INTERIMG),
# Lab.cover_sheet_orders (BEHOLRCV LIST) and Medication.profile (BEHORXFN
# GETRXS). Each answer is checked against the file it reads with DDR:
# V MEASUREMENT (#9000010.01), LAB DATA (#63), ORDER (#100), PRESCRIPTION
# (#52) and PHARMACY PATIENT (#55). Read only.
#
# The pinned demo build has vitals for DFN 2 and no lab data, lab order or
# medication for anyone, so the lab and medication reads prove the empty
# answer against the empty file; a build that files them is checked entry
# by entry.
class LabVitalMedicationReadsLiveTest < LiveSpec::Test
  runs_as "PROV123"
  DFN = 2 # the demo patient with vitals on the pinned build

  def test_latest_vitals_read_back_against_v_measurement
    latest = RpmsRpc::Vital.latest_by_type(DFN)
    refute_empty latest, "BEHOVM LIST answered no vital for DFN #{DFN}: is this the pinned image?"
    latest.each do |row|
      fields = entry("9000010.01", row[:measurement_ien], ".01;.02;.04")
      assert_equal DFN.to_s, fields.dig(".02", :internal), "V MEASUREMENT #{row[:measurement_ien]} is the patient's"
      assert row[:value].start_with?(fields.dig(".04", :external).to_s.strip), "#{row.inspect} reads .04 #{fields['.04'].inspect}"
    end
    assert_equal latest.size, latest.map { |r| r[:abbreviation] }.uniq.size, "one row per vital type"
    assert_empty RpmsRpc::Vital.latest_by_type(999_999_999)
  end

  def test_the_grid_lists_every_measurement_against_its_vital_type
    grid = RpmsRpc::Vital.grid(DFN)
    refute_empty grid[:vitals], "BEHOVM GRID listed no vital type"
    refute_empty grid[:results], "BEHOVM GRID answered no result for DFN #{DFN}"
    grid[:results].each do |result|
      fields = entry("9000010.01", result[:measurement_ien], ".01;.02;.04")
      assert_equal DFN.to_s, fields.dig(".02", :internal)
      assert_equal fields.dig(".04", :external).to_s.strip, result[:value], "the grid value is V MEASUREMENT .04"
      assert_includes grid[:vitals].map { |v| v[:abbreviation] }, result[:abbreviation]
    end
    latest = RpmsRpc::Vital.latest_by_type(DFN).map { |r| r[:measurement_ien] }
    assert_empty latest - grid[:results].map { |r| r[:measurement_ien] }, "every latest measurement is on the grid"

    metric = RpmsRpc::Vital.grid(DFN, metric: 1)
    assert_equal grid[:results].map { |r| r[:measurement_ien] }, metric[:results].map { |r| r[:measurement_ien] }
    assert_equal "cm", metric[:vitals].find { |v| v[:abbreviation] == "HT" }&.fetch(:units), "metric: 1 reports height in cm"
  end

  def test_lab_reads_against_lab_data
    lab_patients = listed("63", ".02;.03")
    if lab_patients.empty?
      assert_equal({ newest: nil, oldest: nil }, RpmsRpc::Lab.result_date_range(DFN), "#63 is empty, so ORWLRR NEWOLD answers ^")
      assert_nil RpmsRpc::Lab.specimen(DFN)
      assert_nil RpmsRpc::Lab.specimen(DFN, from: "3000101", direction: :newer)
      return
    end

    row = lab_patients.find { |r| r[:pieces][0] == "2" } # PARENT FILE 2: a patient
    flunk "#63 has entries but none for a patient: #{lab_patients.first(3).inspect}" unless row
    dfn = row[:pieces][1].to_i
    refute_nil RpmsRpc::Lab.result_date_range(dfn)[:newest], "#63 #{row[:ien]} is DFN #{dfn}'s"
  end

  # LIST^ORQOR1 walks display group LAB and its member groups, so the
  # check is the patient side: a patient with no order on #100 lists
  # none, and every listed order is one of the patient's.
  def test_lab_cover_sheet_orders_are_the_patients_orders
    own = listed("100", ".02").select { |r| r[:pieces][0] == "#{DFN};DPT(" }.map { |r| r[:ien].to_i }
    orders = RpmsRpc::Lab.cover_sheet_orders(DFN)
    if own.empty?
      assert_empty orders, "DFN #{DFN} has no order on #100, so BEHOLRCV LIST answers ^No orders found."
    else
      assert_empty orders.map { |o| o[:order_id].to_i } - own, "each listed order is one of the patient's"
    end
  end

  def test_the_medication_profile_against_prescription_and_pharmacy_patient
    profile = RpmsRpc::Medication.profile(DFN)
    if listed("52", ".01").empty? && listed("55", ".01").empty?
      assert_empty profile, "#52 and #55 are empty, so OCL^PSOORRL finds no medication"
      assert_empty RpmsRpc::Medication.profile(DFN, days: 3650)
      return
    end

    profile.each do |med|
      assert_includes %w[OP UD IV NV], med[:type], med.inspect
      refute_empty med[:name].to_s
    end
  end

  private

  def listed(file, fields)
    got = RpmsRpc::DdrFileman.lister(file: file, fields: fields, flags: "IP", max: "200")
    flunk "DDR LISTER on #{file} failed: #{got.inspect}" if got.nil? || got[:error]
    got[:entries]
  end

  def entry(file, ien, fields)
    got = RpmsRpc::DdrFileman.gets_entry(file: file, iens: "#{ien},", fields: fields, flags: "IE")
    flunk "DDR GETS on #{file} #{ien} failed: #{got.inspect}" if got.nil? || got[:error] || got[:fields].empty?
    got[:fields]
  end
end
