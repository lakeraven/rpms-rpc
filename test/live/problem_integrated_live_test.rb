# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/authentication"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/patient"
require "rpms_rpc/api/problem"

# Problem.integrated, .integrated_entry and .coded_active read IHS's
# integrated problem list through BGOPROB GET, BGOPROB1 GETONE and BGOPROB1
# EDPROB, and Authentication.component_security answers BGOUTL CHKSEC, the
# check VueCentric's BGO components make before they enable editing. All
# four are in CIAV VUECENTRIC.
#
# The spec files a problem with a SNOMED CT concept through Problem.add
# (BGOPROB SET), reads it back through each of the three reads and through
# PROBLEM (#9000011) with DDR, then deletes it and checks the active reads
# no longer list it. The security check is compared with the user's KEYS
# multiple and a parameter set at the user's own entity, then put back.
#
# WRITES against a disposable local container only.
class ProblemIntegratedLiveTest < LiveSpec::Test
  writes!

  DFN = 990_046 # VANTAGE,TAYLOR, a synthetic seed patient; unused by other live specs
  ICD = "E11.9"
  SNOMED = "44054006" # Diabetes mellitus type 2
  PROBLEM_FILE = "9000011"
  PARAM = "BGO DISABLE PROB LIST EDITING"

  def test_a_filed_problem_reads_back_through_the_integrated_list
    refute_nil RpmsRpc::Patient.find(DFN), "DFN #{DFN} must exist on this disposable container"
    stamp = Time.now.utc.strftime("%H%M%S")
    narrative = "SYNTH IPL PROBLEM #{persona} #{stamp}"
    added = RpmsRpc::Problem.add(DFN, icd_code: ICD, snomed_ct: SNOMED, description: narrative,
                                      location_ien: problem_location!, status: "Chronic", onset_date: "11/01/2026")
    assert added[:success], "Problem.add answered #{added.inspect}"
    ien = added[:ien]
    filed = RpmsRpc::DdrFileman.gets_entry(file: PROBLEM_FILE, iens: "#{ien},", fields: ".07;.12;80001", flags: "IE")[:fields]

    listed = RpmsRpc::Problem.integrated(DFN)
    problem = listed.find { |row| row[:ien] == ien }
    refute_nil problem, "BGOPROB GET on DFN #{DFN} lists #{ien}: #{listed.map { |r| r[:ien] }.inspect}"
    assert_equal SNOMED, problem[:snomed_concept], "the SNOMED CT concept filed in 80001"
    assert_equal SNOMED, filed.dig("80001", :internal)
    assert_equal ICD, problem[:icd_code]
    assert_equal "*#{narrative}", problem[:narrative].split("|").first
    assert_equal "CHRONIC", problem[:status]
    assert_equal Date.new(2026, 11, 1), problem[:onset]
    assert_match(/-#{filed.dig('.07', :internal)}\z/, problem[:number], "the facility-scoped number ends in .07 NMBR")

    assert_equal problem.except(:other), RpmsRpc::Problem.integrated_entry(ien)&.except(:other),
                 "BGOPROB1 GETONE answers the problem as BGOPROB GET lists it"

    coded = RpmsRpc::Problem.coded_active(DFN).find { |row| row[:ien] == ien }
    refute_nil coded, "BGOPROB1 EDPROB lists #{ien} (active, with a SNOMED CT concept)"
    assert_equal [ SNOMED, ICD, "CHRONIC" ], coded.values_at(:snomed_ct, :icd_code, :status)

    assert_empty RpmsRpc::Problem.integrated(DFN, statuses: "I").select { |row| row[:ien] == ien },
                 "an inactive-only list does not list an active problem"

    deleted = RpmsRpc::Problem.delete(DFN, ien, reason: "Entered in error")
    assert deleted[:success], "Problem.delete answered #{deleted.inspect}"
    assert_nil RpmsRpc::Problem.integrated(DFN).find { |row| row[:ien] == ien }, "a deleted problem is not listed"
    assert_nil RpmsRpc::Problem.integrated_entry(ien), "GETONE answers nothing for a deleted problem"
    assert_nil RpmsRpc::Problem.coded_active(DFN).find { |row| row[:ien] == ien }, "EDPROB does not list a deleted problem"
    assert_nil RpmsRpc::Problem.integrated_entry(999_999_999)

    puts "\n#{persona}: PROBLEM #{ien} (SNOMED #{SNOMED}) reads back through BGOPROB GET, GETONE and EDPROB"
  end

  def test_component_security_answers_the_users_keys_and_parameter_settings
    held = RpmsRpc::Authentication.user_security_keys(client.duz)
    keys = [ held.first, "ZZ NO SUCH KEY" ].compact
    answer = RpmsRpc::Authentication.component_security(keys: keys, parameters: [ PARAM ])
    assert_equal keys.to_h { |k| [ k, held.include?(k) ] }, answer[:keys], "CHKSEC's key flags match the KEYS multiple"
    before = answer[:parameters].fetch(PARAM)

    set_user_parameter(PARAM, before[:user_setting].zero? ? "1" : "0")
    after = RpmsRpc::Authentication.component_security(parameters: [ PARAM ])[:parameters].fetch(PARAM)
    assert_equal before[:user_setting].zero? ? 1 : 0, after[:user_setting], "the user's own setting, as just filed"
    assert_equal before[:granted_by_class], after[:granted_by_class], "a user-level value does not change the class grant"
  ensure
    set_user_parameter(PARAM, before[:user_setting].zero? ? "@" : before[:user_setting].to_s) if before
  end

  private

  # The INSTITUTION the build's own problems are numbered under (.06).
  def problem_location!
    listed = RpmsRpc::DdrFileman.lister(file: PROBLEM_FILE, fields: ".06", flags: "IP", max: "1")
    flunk "DDR LISTER on PROBLEM failed: #{listed.inspect}" if listed.nil? || listed[:error]
    row = listed[:entries].first
    flunk "no PROBLEM on file to take a location from: is this the pinned image?" if row.nil?
    row[:pieces].first
  end

  # The fixture: the parameter at the signed-on user's own entity, through
  # the XPAR writer VueCentric saves user settings with (SETPAR^CIAVMRPC ->
  # EN^XPAR, "@" deletes). It answers "" or 0 on success, else n^text.
  def set_user_parameter(name, value)
    client.create_context("CIAV VUECENTRIC")
    reply = Array(client.call_rpc("CIAVMRPC SETPAR", name, value, "USR", "1")).join
    flunk "CIAVMRPC SETPAR #{name} = #{value} answered #{reply.inspect}" unless reply.empty? || reply == "0"
  end
end
