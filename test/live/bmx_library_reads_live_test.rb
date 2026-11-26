# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/bmx"

# The BMXNet library's own RPCs (BMX under BMXRPC), the calls IHS's .NET
# registration and scheduling clients make around theirs, as the front desk
# clerk (PROFILE,REG) and the registration supervisor (PROFILE,REGSUP), on
# the demo division DEMO IHS CLINIC (#4 7819) and the panel patient
# QUEBEC,SAGE (DFN 990017, chart 990017, born 06/09/2001, two PCC-linked
# behavioral health visits on 10/14 and 10/28/2026). Every broker role's row
# holds BMXRPC, so no role is refused these and the spec has no refusal
# side; the key reads differ by role instead. Reads only.
class BmxLibraryReadsLiveTest < LiveSpec::Test
  runs_as :front_desk_clerk, :registration_supervisor

  B = RpmsRpc::Bmx
  DFN = 990_017

  def test_who_the_user_is_their_facility_and_their_keys
    assert_equal role_row.account, B.user_name(client.duz)
    assert_equal [ { name: "DEMO IHS CLINIC", ien: 7819, most_recent: true } ], B.facilities(client.duz)
    assert_includes B.user_keys(client.duz), "AGZMENU"
    assert B.holds_key?("AGZMENU")
    supervisor = role == :registration_supervisor
    assert_equal supervisor, B.holds_key?("AGZMGR"), "AGZMGR is the supervisor's (README, Test roles)"
    assert_equal supervisor, B.user_keys(client.duz).include?("AGZMGR")
    refute B.holds_key?("NO SUCH KEY")
  end

  def test_the_library_version_and_the_keep_alive
    assert_equal({ major: 1, minor: 0, build: "3050613.12" }, B.version("BMX"))
    assert B.alive?
  end

  def test_the_patient_lookups_find_her
    found = B.find_patients("QUEBEC,SAGE").find { |p| p[:dfn] == DFN } || flunk("BMX FIND PATIENT did not find DFN #{DFN}")
    assert_equal({ name: "QUEBEC,SAGE", sex: "F", chart: "990017", classification: "INDIAN/ALASKA NATIVE" },
                 found.slice(:name, :sex, :chart, :classification))
    assert_equal [ { dfn: DFN, name: "QUEBEC,SAGE", hrn: "990017", dob: Date.new(2001, 6, 9) } ], B.patient_lookup("QUEBEC,SAGE")
    assert_equal({ name: "QUEBEC,SAGE", sex: "F", dob: Date.new(2001, 6, 9) }, B.patients_from("QUEBEC,SAGE", count: 1).first)
  end

  def test_her_banner_chart_and_info
    assert_equal({ dob: "09-Jun-2001", sex: "Female", chart: "99-00-17" }, B.banner(DFN).slice(:dob, :sex, :chart))
    chart = B.chart("990017")
    assert_equal [ "QUEBEC,SAGE", Date.new(2001, 6, 9) ], chart.values_at(:name, :dob)
    refute_nil chart[:street], "the panel carries a street address"
    info = B.patient_info(DFN)
    assert_equal [ DFN, "QUEBEC,SAGE", "990017", "Female" ], info.values_at(:dfn, :name, :hrn, :sex)
    assert_match(/\A\d+ years\z/, info[:age])
  end

  def test_her_recent_visits_are_the_behavioral_health_ones
    visits = B.recent_visits(DFN, max: 2)
    assert_equal 2, visits.size
    newest = visits.first
    assert_equal "OCT 28, 2026@14:00", newest[:timestamp]
    assert_equal [ DFN, "DEMO IHS CLINIC", "AMBULATORY", "MENTAL HEALTH (PSYCHIATRY)", "PROFILE,BH" ],
                 newest.values_at(:dfn, :location, :service_category, :clinic, :provider)
    assert_match(/\AF32\.9 /, newest[:pov])
  end

  def test_the_schema_reads_and_sql
    assert_includes B.fields(9_999_999.03), { number: ".01", label: "NAME" }
    assert_includes B.multiples(2), { number: "2.01", name: "ALIAS" }
    assert_includes B.files(from: "PATIENT", to: "PATIENTZ"), { name: "PATIENT", number: "9000001" }
    assert_equal [ { name: "QUEBEC,SAGE", sex: "FEMALE" } ], B.sql("SELECT NAME, SEX FROM PATIENT WHERE NAME LIKE 'QUEBEC,S%'")
    assert_equal %w[name sex], B.sql_columns("SELECT NAME, SEX FROM PATIENT")
    names = B.find(200, "PROFILE,", max: 30).map { |r| r[:name] }
    assert_includes names, "PROFILE,REG"
    assert_includes names, "PROFILE,SCHED"
  end
end
