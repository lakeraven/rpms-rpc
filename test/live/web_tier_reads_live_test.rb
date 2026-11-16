# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/session"
require "rpms_rpc/api/vital"
require "rpms_rpc/api/medication"
require "rpms_rpc/api/reminders"
require "rpms_rpc/api/scheduling"

# The reads lakeraven-ehr makes through the gem that had no live proof:
# Session.bootstrap (CIAVCXUS VIMINFO), Vital.for_patient (ORQQVI VITALS),
# Vital.template (BEHOVM TEMPLATE), Medication.active_for_patient
# (ORWPS ACTIVE), Reminders.applicable (ORQQPXRM REMINDERS APPLICABLE) and
# Scheduling.clinic_setup (BSDX CLINIC SETUP). Reads only.
class WebTierReadsLiveTest < LiveSpec::Test
  DFN = 4 # DEMO,PATIENT ONE on the pinned build
  CLINIC = 3 # DEMO IHS CLINIC, HOSPITAL LOCATION #44
  NO_SUCH_DUZ = 999_999_999

  # VIMINFO^CIAVCXUS answers DUZ^NAME^PTMOUT;STMOUT;CNTDN^COMPOSE^DESIGN for
  # the user it is given, and "" for a DUZ with no NEW PERSON entry.
  def test_bootstrap_answers_the_signed_on_users_vim_info
    info = RpmsRpc::Session.bootstrap(client.duz)[:vim_info]
    assert_equal client.duz.to_i, info[:duz]
    assert_match(/\A[A-Z' -]+,[A-Z' -]+\z/, info[:user_name])
    assert_match(/\A\d+;\d+;\d+\z/, info[:timeouts], "primary;secondary;countdown")
    assert_includes [ true, false ], info[:compose_mode]
    assert_includes [ true, false ], info[:design_mode]

    assert_equal({ vim_info: {} }, RpmsRpc::Session.bootstrap(NO_SUCH_DUZ))
  end

  def test_vitals_for_patient_are_measurements_with_their_times
    rows = RpmsRpc::Vital.for_patient(DFN)
    refute_empty rows, "ORQQVI VITALS gave no vital for DFN #{DFN}"
    rows.each do |row|
      assert_kind_of Integer, row[:measurement_ien]
      assert_match(/\A[A-Z0-9]+\z/, row[:type])
      refute_empty row[:value].to_s
      assert_kind_of Time, row[:recorded_date], "a vital without its date: #{row.inspect}"
    end
    assert_equal rows.map { |r| r[:measurement_ien] }.uniq.size, rows.size

    newest = rows.map { |r| r[:recorded_date] }.max
    after = newest.to_date + 1
    assert_empty RpmsRpc::Vital.for_patient(DFN, start_date: after, end_date: after + 1), "the date range is sent and honoured"
  end

  # GRID^BEHOVM's count header is not a vital: every row is a vital type
  # with a name and an abbreviation, and metric: 1 asks for metric units.
  def test_vital_template_lists_the_vital_types_and_no_header
    vstr = "#{CLINIC};#{RpmsRpc::FilemanDateParser.to_fileman(Date.today)};A;"
    rows = RpmsRpc::Vital.template(DFN, vstr)
    refute_empty rows, "BEHOVM TEMPLATE listed no vital type"
    rows.each do |row|
      assert_operator row[:ien], :>, 0
      refute_empty row[:name].to_s
      refute_nil row[:abbreviation], "a template row without an abbreviation (the count header?): #{row.inspect}"
    end
    assert_empty %w[TMP PU RS BP HT WT] - rows.map { |r| r[:abbreviation] }
    assert_equal "F", rows.find { |r| r[:abbreviation] == "TMP" }[:units]

    metric = RpmsRpc::Vital.template(DFN, vstr, metric: 1)
    assert_equal "C", metric.find { |r| r[:abbreviation] == "TMP" }[:units]
  end

  # ACTIVE^ORWPS takes the patient alone (USER defaults to DUZ, VIEW to 1).
  # The demo build files no medication, so the reply is empty; a row, when
  # a build has one, carries a name.
  def test_active_medications_answer_without_an_error
    rows = RpmsRpc::Medication.active_for_patient(DFN)
    assert_kind_of Array, rows
    rows.each { |row| refute_empty row[:name].to_s, "an active medication without a name: #{row.inspect}" }
    puts "\n#{persona}: active_for_patient(#{DFN}) answered #{rows.size} row(s)"
  end

  def test_applicable_reminders_carry_a_status_from_their_due_flag
    rows = RpmsRpc::Reminders.applicable(DFN.to_s, CLINIC.to_s)
    refute_empty rows, "ORQQPXRM REMINDERS APPLICABLE listed no reminder for DFN #{DFN}"
    rows.each do |row|
      assert_operator row[:id], :>, 0
      refute_empty row[:name].to_s
      assert_equal RpmsRpc::Reminders::STATUS_BY_DUE_FLAG.fetch(row[:due_flag]), row[:status]
    end
    assert(rows.any? { |r| r[:status] == :due }, "no reminder due for DFN #{DFN}: #{rows.inspect}")
  end

  def test_clinic_setup_lists_hospital_locations_and_no_header
    rows = RpmsRpc::Scheduling.clinic_setup
    refute_empty rows, "BSDX CLINIC SETUP listed no clinic"
    rows.each do |row|
      assert_operator row[:location_ien].to_i, :>, 0, "a row whose location is not an IEN (the header?): #{row.inspect}"
      refute_empty row[:location].to_s
    end
    demo = rows.find { |r| r[:location_ien].to_i == CLINIC } || flunk("DEMO IHS CLINIC has no clinic setup row: #{rows.inspect}")
    assert_equal "DEMO IHS CLINIC", demo[:location]
    assert_equal "YES", demo[:create_visit]
  end
end
