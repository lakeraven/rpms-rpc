# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/immunization_refusal"
require "rpms_rpc/api/problem"
require "rpms_rpc/api/ddr_fileman"

# Two writes whose routine answers nothing on success: SET^BGOREF (BGOREF
# SET, ImmunizationRefusal.record) leaves RET "" and DEL^BGOPROB3 (BGOPROB
# DEL, Problem.delete) leaves the falsy RET of $$UPDATE^BGOUTL; both answer
# -CODE^text on error. Both are single-value RPCs (#8994 RETURN VALUE TYPE 1).
#
# Over the wire an empty RET arrives as no lines ([]), and both APIs used to
# accept only a String reply, so each reported a write RPMS had filed as a
# failure. Each spec files the write, asserts the API says it went through,
# and reads the result back with DDR. A bad patient must still fail.
#
# It WRITES, so it runs only against a disposable local container.
class EmptyReplyWritesLiveTest < LiveSpec::Test
  writes!

  REFUSAL_FILE = "9000022"   # PERSONAL HISTORY REFUSALS (^AUPNPREF)
  PROBLEM_FILE = "9000011"   # PROBLEM (^AUPNPROB)
  REFUSAL_DFN = "990002"     # BRAVO,ALEX, a synthetic seed patient
  PROBLEM_DFN = "990013"     # MIKE,SKYLER, a synthetic seed patient
  TETANUS_TOXOID = "104"     # IMMUNIZATION (#9999999.14)

  def test_a_filed_refusal_reports_success_and_reads_back
    reason = RpmsRpc::ImmunizationRefusal.reasons.first
    refute_nil reason, "the build lists no refusal reasons (GETREA^BGOREF)"
    before = refusal_iens

    result = RpmsRpc::ImmunizationRefusal.record(REFUSAL_DFN, TETANUS_TOXOID, reason_ien: reason[:ien],
                                                 narrative: "live spec")

    assert result[:success], "record answered #{result.inspect}"
    filed = refusal_iens - before
    assert_equal 1, filed.size, "expected one new refusal for DFN #{REFUSAL_DFN}, found #{filed.inspect}"
    puts "\n#{persona}: refusal #{filed.first} filed for DFN #{REFUSAL_DFN}, record reported success"
  end

  def test_a_refusal_for_an_unknown_patient_is_a_failure
    result = RpmsRpc::ImmunizationRefusal.record("999999999", TETANUS_TOXOID, reason_ien: "2")

    refute result[:success], "record for an unknown patient answered #{result.inspect}"
    assert_match(/\A-1001\^/, Array(result[:raw]).first.to_s)
  end

  def test_a_deleted_problem_reports_success_and_reads_back_deleted
    problem = RpmsRpc::Problem.for_patient(PROBLEM_DFN).find { |p| p[:status] == "A" }
    refute_nil problem, "DFN #{PROBLEM_DFN} has no active problem to delete"
    ien = problem[:ien]
    begin
      result = RpmsRpc::Problem.delete(PROBLEM_DFN, ien, reason: "live spec")

      assert result[:success], "delete answered #{result.inspect}"
      assert_equal "D", problem_status(ien), "problem #{ien} is not deleted after delete"
      puts "\n#{persona}: problem #{ien} deleted, status read back D"
    ensure
      restore_active(ien)
    end
  end

  private

  def refusal_iens
    listed = RpmsRpc::DdrFileman.lister(file: REFUSAL_FILE, fields: ".02I", flags: "IP", xref: "AC", part: REFUSAL_DFN)
    refute_nil listed, "DDR LISTER on #{REFUSAL_FILE} answered nothing"
    listed[:entries].select { |e| e[:pieces].first == REFUSAL_DFN }.map { |e| e[:ien] }
  end

  def problem_status(ien)
    got = RpmsRpc::DdrFileman.gets_entry(file: PROBLEM_FILE, iens: "#{ien},", fields: ".12", flags: "I")
    got&.dig(:fields, ".12", :internal)
  end

  # STATUS .12 back to A so a rerun finds the same active problem.
  def restore_active(ien)
    RpmsRpc::DdrFileman.filer(mode: "EDIT", rows: [ { file: PROBLEM_FILE, field: ".12", iens: "#{ien},", value: "A" } ])
    assert_equal "A", problem_status(ien), "problem #{ien} could not be filed active again"
  end
end
