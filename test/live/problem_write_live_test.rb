# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/patient"
require "rpms_rpc/api/problem"
require "rpms_rpc/fileman_date_parser"

# Problem.add, .update and .delete write through IHS's BGOPROB SET and BGOPROB
# DEL (SET^BGOPROB -> PROB^BGOPROB3, DEL^BGOPROB3), the writes VueCentric uses
# on RPMS; stock ORQQPL stays read-only in the gem (rpms-rpc#527). Both RPCs
# are in CIAV VUECENTRIC, the option CIA sign-on binds.
#
# The spec adds a problem, edits it, refuses an edit and a delete named with
# another patient, then deletes it, and reads the PROBLEM (#9000011) entry back
# with DDR after each step: what was filed, by whom, and what the delete
# recorded.
#
# WRITES against a disposable local container only.
class ProblemWriteLiveTest < LiveSpec::Test
  writes!

  DFN = 990_055 # a synthetic seed patient; unused by other live specs
  OTHER_DFN = 990_056
  ICD = "F32.9"
  PROBLEM_FILE = "9000011"
  FIELDS = ".01;.02;.05;.06;.12;.13;.14;1.03;1.04;2.01;2.02;2.03"

  def test_add_edit_and_delete_a_problem_read_back_with_ddr
    assert_synthetic_patient!(DFN)
    assert_synthetic_patient!(OTHER_DFN)
    duz = client.duz.to_s
    location = problem_location!
    stamp = Time.now.utc.strftime("%H%M%S")
    narrative = "SYNTH LIVE PROBLEM #{persona} #{stamp}"
    problem = { icd_code: ICD, description: narrative, location_ien: location, status: "Chronic", onset_date: "11/01/2026" }

    added = RpmsRpc::Problem.add(DFN, problem)
    assert added[:success], "Problem.add answered #{added.inspect}"
    ien = added[:ien]
    row = entry(ien)
    assert_equal ICD, row.dig(".01", :external), "PROBLEM #{ien} .01 is not the ICD sent"
    assert_equal DFN.to_s, row.dig(".02", :internal), "PROBLEM #{ien} .02 is not the patient"
    assert_equal "*#{narrative}", row.dig(".05", :external).split("|").first, "PROBLEM #{ien} .05 is not the narrative sent"
    assert_equal location, row.dig(".06", :internal), "PROBLEM #{ien} .06 is not the location sent"
    assert_equal "A", row.dig(".12", :internal), "Chronic files as status A (PROB^BGOPROB3)"
    assert_equal "3261101", row.dig(".13", :internal), "PROBLEM #{ien} .13 is not the onset sent"
    %w[.14 1.03 1.04].each { |f| assert_equal duz, row.dig(f, :internal), "PROBLEM #{ien} #{f} is not the signed-on user" }

    edited_text = "SYNTH LIVE PROBLEM EDITED #{stamp}"
    edited = RpmsRpc::Problem.update(DFN, ien, problem.merge(status: "Inactive", description: edited_text))
    assert_equal({ success: true, ien: ien, raw: ien.to_s }, edited)
    row = entry(ien)
    assert_equal "I", row.dig(".12", :internal), "Inactive files as status I"
    assert_equal "*#{edited_text}", row.dig(".05", :external).split("|").first, "the edit did not file the new narrative"
    assert_equal DFN.to_s, row.dig(".02", :internal), "an edit must not move the problem"

    assert_equal :wrong_patient, RpmsRpc::Problem.update(OTHER_DFN, ien, problem)[:error]
    assert_equal :wrong_patient, RpmsRpc::Problem.delete(OTHER_DFN, ien, reason: "Entered in error")[:error]
    assert_equal "I", entry(ien).dig(".12", :internal), "a refused edit or delete changed PROBLEM #{ien}"

    before = server_now
    deleted = RpmsRpc::Problem.delete(DFN, ien, reason: "Entered in error")
    assert deleted[:success], "Problem.delete answered #{deleted.inspect}"
    row = entry(ien)
    assert_equal "D", row.dig(".12", :internal), "the delete is logical: .12 D (DEL^BGOPROB3)"
    assert_equal duz, row.dig("2.01", :internal), "2.01 is not the user who deleted it"
    deleted_at = RpmsRpc::FilemanDateParser.parse_datetime(row.dig("2.02", :internal))
    assert deleted_at && deleted_at >= before, "2.02 #{row.dig('2.02', :internal).inspect} is not this delete's time"
    assert_equal "Entered in error", row.dig("2.03", :internal), "2.03 is not the reason sent"

    assert_equal :not_found, RpmsRpc::Problem.delete(DFN, 999_999_999, reason: "Entered in error")[:error]
    puts "\n#{persona}: PROBLEM #{ien} on DFN #{DFN} added, edited and deleted through BGOPROB SET / DEL"
  end

  private

  def entry(ien)
    got = RpmsRpc::DdrFileman.gets_entry(file: PROBLEM_FILE, iens: "#{ien},", fields: FIELDS, flags: "IE")
    flunk "DDR GETS on PROBLEM #{ien} failed: #{got.inspect}" if got.nil? || got[:error]
    got[:fields]
  end

  # The INSTITUTION the build's own problems are numbered under (.06).
  def problem_location!
    listed = RpmsRpc::DdrFileman.lister(file: PROBLEM_FILE, fields: ".06", flags: "IP", max: "1")
    flunk "DDR LISTER on PROBLEM failed: #{listed.inspect}" if listed.nil? || listed[:error]
    row = listed[:entries].first
    flunk "no PROBLEM on file to take a location from: is this the pinned image?" if row.nil?
    row[:pieces].first
  end

  def assert_synthetic_patient!(dfn)
    refute_nil RpmsRpc::Patient.find(dfn), "DFN #{dfn} must exist on this disposable container's seed data"
  end

  def server_now
    value = Array(client.call_rpc("ORWU DT", "NOW")).first.to_s
    now = RpmsRpc::FilemanDateParser.parse_datetime(value) || flunk("ORWU DT NOW did not yield a FileMan datetime: #{value.inspect}")
    Time.new(now.year, now.month, now.day, now.hour, now.min, 0)
  end
end
