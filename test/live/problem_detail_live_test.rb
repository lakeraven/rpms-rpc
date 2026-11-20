# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/problem"

# Problem.details reads ORQQPL DETAIL (DETAIL^ORQQPL), in CIAV VUECENTRIC,
# on the problems the build seeds in PROBLEM (#9000011). The reply is the
# display report DETAIL builds, one text line per Y(I) (ORQQPL.m:26-59),
# not a caret row (#821). These specs read only; they file nothing.
class ProblemDetailLiveTest < LiveSpec::Test
  runs_as "PROV123"

  PROBLEM_FILE = "9000011"

  # The first line is NARRATIVE (DIAGNOSIS), and the labelled lines follow;
  # the Status line is ACTIVE or INACTIVE, with /ACUTE or /CHRONIC from the
  # problem's priority (ORQQPL.m:31-32).
  def test_details_is_the_problems_report_text
    ien, dfn, = first_problem
    text = RpmsRpc::Problem.details(dfn, ien)

    assert_kind_of String, text
    lines = text.split("\n")
    assert_match(/\S.* \(.*\)\z/, lines.first, "the first line is NARRATIVE (DIAGNOSIS)")
    refute_match(/\A\d+\z/, lines.first)
    [ "   Onset: ", " SC Cond: ", "Exposure: ", "Provider: ", "  Clinic: ", "Recorded: ", " Entered: ", " Updated: " ].each do |label|
      assert(lines.any? { |l| l.start_with?(label) }, "no #{label.strip} line in #{lines.inspect}")
    end
    status_line = lines.find { |l| l.start_with?("  Status: ") }
    assert_match(%r{\A  Status: (ACTIVE|INACTIVE)(/ACUTE|/CHRONIC)?\z}, status_line.to_s)
  end

  # DETAIL declares DFN and never reads it (ORQQPL.m:21-59): any patient
  # gets the same report for a problem.
  def test_details_does_not_read_the_patient
    ien, dfn, = first_problem
    other = problems.map { |_, d| d }.find { |d| d != dfn }
    flunk "PROBLEM (#{PROBLEM_FILE}) holds problems for one patient only" if other.nil?

    assert_equal RpmsRpc::Problem.details(dfn, ien), RpmsRpc::Problem.details(other, ien)
  end

  # A problem not on file dies in M: DETAIL^GMPLUTL2 leaves
  # ORGMPL("NARRATIVE") undefined and DETAIL reads it (ORQQPL.m:26).
  def test_details_of_a_problem_not_on_file_raises_the_m_error
    ien, dfn, = first_problem
    unknown = problems.map { |i, _| i.to_i }.max + 1
    error = assert_raises(RpmsRpc::Client::RpcMError) { RpmsRpc::Problem.details(dfn, unknown) }
    assert_includes error.message, "LVUNDEF"
    refute_nil ien
  end

  private

  # [[IEN, DFN]] of every problem in #9000011.
  def problems
    @problems ||= begin
      listed = RpmsRpc::DdrFileman.lister(file: PROBLEM_FILE, fields: "@;.02", flags: "IP")
      flunk "DDR LISTER on PROBLEM (#{PROBLEM_FILE}) gave no reply" if listed.nil? || listed[:error]

      listed[:entries].map { |e| [ e[:ien], e[:pieces][0].to_s ] }
    end
  end

  def first_problem
    problems.first || flunk("PROBLEM (#{PROBLEM_FILE}) holds no problem on this build")
  end
end
