# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/behavioral_health/reference"
require "rpms_rpc/api/behavioral_health/intake"
require "rpms_rpc/api/behavioral_health/groups"
require "rpms_rpc/api/behavioral_health/case_management"

# The AMHG reference, intake, group and case-management reads over the wire
# (rpms-rpc#622, #673), under AMHGRPC. Each answers parsed rows, never the
# recordset's typed header read as a record. Reads only.
# Needs a persona AMHGRPC lets run these reads (the operator, SYS123).
class BehavioralHealthReferenceLiveTest < LiveSpec::Test
  BH = RpmsRpc::BehavioralHealth
  DEMO_DFN = "4" # DEMO,PATIENT ONE on the pinned build (patient_live_test.rb)
  FROM = "3000101"
  TO = "3271231"
  NOT_ON_FILE = "999999"

  def test_patients_finds_the_demo_patient_and_no_header
    rows = BH::Reference.patients("DEMO")
    refute_empty rows, "AMHG GET PATIENT found no DEMO patient"
    rows.each { |row| assert_match(/\A\d+\z/, row[:ien], "a row whose IEN is not a DFN: #{row.inspect}") }
    assert_includes rows.map { |r| r[:ien] }, DEMO_DFN
    assert_empty BH::Reference.patients("ZZZNOMATCH#{rand(10**6)}")
  end

  def test_single_record_reads_answer_the_ien_asked_for
    assert_equal "1", BH::Reference.site_parameters(1)[:ien]
    assert_equal NOT_ON_FILE, BH::Groups.group_information(NOT_ON_FILE)[:ien]
    assert_equal NOT_ON_FILE, BH::CaseManagement.case_management(NOT_ON_FILE)[:ien]
    assert_equal NOT_ON_FILE, BH::CaseManagement.community_activity(NOT_ON_FILE)[:ien]
  end

  def test_group_soap_for_a_group_not_on_file_has_no_header_line
    assert_empty BH::Groups.group_soap(NOT_ON_FILE)
  end

  # ADML^AMHGDA dies at +32 (AMHPOVE undefined) once the provider has an
  # administrative BH record with no POV, which the BH save live specs file
  # (lakeraven/rpms-ops#1119). Its trap answers an "M ERROR|" row and no
  # $C(31), and the read raises it (rpms-rpc#706). That is IRIS, and YottaDB
  # from bcer-9.0-20261110-55d9e3e (rpms-ops#1127); an older YottaDB image
  # overwrites the error row with $C(31) and answers no rows.
  def test_admin_records_answer_record_rows_or_raise_the_builds_adml_error
    rows = BH::Reference.admin_records(client.duz.to_s, from: FROM, to: TO)
    rows.each { |row| assert_match(/\A\d+\z/, row[:ien].to_s, "a row whose IEN is not a record IEN: #{row.inspect}") }
    puts "\n#{persona}: admin_records answered #{rows.size} row(s)"
  rescue RpmsRpc::Client::RpcMError => e
    assert_match(/ADML\+32\^AMHGDA/, e.message, "an M error other than rpms-ops#1119")
    puts "\n#{persona}: admin_records raised the build's ADML error (rpms-ops#1119)"
  end

  def test_lists_answer_rows_with_record_iens_only
    duz = client.duz.to_s
    lists = {
      intakes: BH::Intake.intakes(DEMO_DFN, from: FROM, to: TO),
      intake_documents: BH::Intake.intake_documents(DEMO_DFN, program: "M", from: FROM, to: TO),
      groups: BH::Groups.groups(duz, from: FROM, to: TO),
      group_patients: BH::Groups.group_patients(NOT_ON_FILE),
      case_dates: BH::CaseManagement.case_dates(DEMO_DFN, from: FROM, to: TO),
      community_activities: BH::CaseManagement.community_activities(duz, from: FROM, to: TO)
    }
    lists.each do |name, rows|
      assert_kind_of Array, rows
      rows.each { |row| assert_match(/\A\d+\z/, row[:ien].to_s, "#{name}: a row whose IEN is not a record IEN: #{row.inspect}") }
      puts "\n#{persona}: #{name} answered #{rows.size} row(s)"
    end
  end
end
