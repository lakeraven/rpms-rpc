# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/patient_goal"

# PatientGoal.for_patient over BEHOPGAP GETGOAL (CIAV VUECENTRIC), the read
# VueCentric's Patient Goals component lists a patient's goals with. The spec
# files a goal with two types and a review through BEHOPGAP ADDGOAL and
# ADDREV, the component's own writers (the fixture), reads it back through
# GETGOAL, and checks it against PATIENT GOALS (#9000093) with DDR.
#
# WRITES against a disposable local container only.
class PatientGoalLiveTest < LiveSpec::Test
  runs_as "PROV123"
  writes!

  DFN = 990_044 # THISTLEDOWN,RILEY, a synthetic seed patient; unused by other live specs
  GOAL_FILE = "9000093"
  TYPES = [ "PHYSICAL ACTIVITY", "NUTRITION" ].freeze

  def test_a_filed_goal_reads_back_with_its_types_and_review
    facility = facility!
    stamp = Time.now.utc.strftime("%H%M%S")
    name = "Walk 30 minutes a day #{persona} #{stamp}"
    number = rpc("BEHOPGAP NEXTGN", DFN.to_s, facility).to_s
    flunk "BEHOPGAP NEXTGN answered #{number.inspect}" unless number.match?(/\A\d+\z/)

    gdat = { "1" => "GOAL^S^#{facility}^#{number}^#{client.duz}^3261116^3261216^", "2" => "TYPE^#{TYPES.join('^')}",
             "3" => "NAME^#{name}", "4" => "REASON^Blood sugar control" }
    ien = rpc("BEHOPGAP ADDGOAL", DFN.to_s, gdat).to_s
    flunk "BEHOPGAP ADDGOAL answered #{ien.inspect}" unless ien.match?(/\A[1-9]\d*\z/)
    added = rpc("BEHOPGAP ADDREV", ien, "3261120", "Walked three days this week").to_s
    flunk "BEHOPGAP ADDREV answered #{added.inspect}" if added.start_with?("0^")

    goal = RpmsRpc::PatientGoal.for_patient(DFN).find { |g| g[:ien] == ien.to_i }
    refute_nil goal, "BEHOPGAP GETGOAL lists goal #{ien} for DFN #{DFN}"
    assert_equal [ number.to_i, "GOAL SET", "A", name, "Blood sugar control", TYPES ],
                 goal.values_at(:goal_number, :setting, :status, :name, :reason, :types)
    assert_equal [ Date.new(2026, 11, 16), Date.new(2026, 12, 16) ], goal.values_at(:start_date, :follow_up_date)
    assert_equal [ { date: Date.new(2026, 11, 20), note: "Walked three days this week" } ], goal[:reviews]

    fields = RpmsRpc::DdrFileman.gets_entry(file: GOAL_FILE, iens: "#{ien},", fields: ".02;.07;.11;1101", flags: "IE")[:fields]
    assert_equal [ DFN.to_s, number, "A" ], fields.values_at(".02", ".07", ".11").map { |f| f[:internal] }
    assert_equal name, fields.dig("1101", :external)

    # GETGOAL's deleted-goal skip compares "D;DELETED/..." with "D"
    # (BEHOPGAP.m:118), so a deleted goal is still listed, by its status.
    deleted = rpc("BEHOPGAP DELGOAL", ien, client.duz.to_s, "", "D", "").to_s
    flunk "BEHOPGAP DELGOAL answered #{deleted.inspect}" unless deleted == "1"
    gone = RpmsRpc::PatientGoal.for_patient(DFN).find { |g| g[:ien] == ien.to_i }
    assert_equal "D", gone&.dig(:status), "a deleted goal is listed with status D: #{gone.inspect}"

    assert_empty RpmsRpc::PatientGoal.for_patient(999_999_999)
    puts "\n#{persona}: goal #{ien} (number #{number}) on DFN #{DFN} reads back through BEHOPGAP GETGOAL"
  end

  private

  def rpc(name, *params)
    client.create_context("CIAV VUECENTRIC")
    Array(client.call_rpc(name, *params)).first
  end

  # The facility (#9999999.06 LOCATION) the build's own problems are numbered under.
  def facility!
    listed = RpmsRpc::DdrFileman.lister(file: "9000011", fields: ".06", flags: "IP", max: "1")
    flunk "DDR LISTER on PROBLEM failed: #{listed.inspect}" if listed.nil? || listed[:error] || listed[:entries].empty?
    listed[:entries].first[:pieces].first
  end
end
