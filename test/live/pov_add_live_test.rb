# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/encounter"
require "rpms_rpc/api/patient"
require "rpms_rpc/api/pov"
require "rpms_rpc/api/problem"
require "rpms_rpc/fileman_date_parser"

# Pov.add files a visit diagnosis from a problem-list entry through BGOVPOV
# SET (SET^BGOVPOV -> SET2^BGOVPOV2), in CIAV VUECENTRIC. The problem is
# required: GETDATA^BGOVPOV2 walks ^AUPNPROB(PROB,13,...) with the problem
# sent in INP piece 3, and with that piece empty the build errors with a null
# subscript (rpms-rpc#922). A visit diagnosis with no problem goes through
# Encounter.save (BEHOENPC SAVE) instead. The diagnosis is sent with its
# SNOMED concept, as VueCentric sends it: without one SET2^BGOVPOV2 answers
# -1092 ("The specified ICD9 code is not recognized") on the pinned build.
#
# The spec opens a visit and files a problem for a synthetic patient, refuses
# Pov.add with no problem (nothing is filed in V POV), then adds the diagnosis
# against the problem and reads the V POV (#9000010.07) back with DDR: its
# visit, patient, diagnosis and .16 PROBLEM.
#
# WRITES against a disposable local container only.
class PovAddLiveTest < LiveSpec::Test
  runs_as :provider
  writes!

  DFN = 990_051 # a synthetic seed patient; the only other spec that names it reads its coverage
  LOCATION_IEN = 6
  ICD = "F32.9"
  SNOMED = "35489007" # Depressive disorder; $$CONC^BSTSAPI maps it to F32.9
  POV_FILE = "9000010.07"
  PROBLEM_FILE = "9000011"

  def test_add_without_a_problem_is_refused_and_files_nothing
    refute_nil RpmsRpc::Patient.find(DFN), "DFN #{DFN} must exist on this disposable container's seed data"
    visit = open_visit!
    before = newest(POV_FILE)

    result = RpmsRpc::Pov.add(DFN, visit, ICD, narrative: "SYNTH LIVE POV no problem")

    refute result[:success], result.inspect
    assert_nil result[:raw], "nothing should reach BGOVPOV SET: #{result.inspect}"
    assert_includes result[:error].to_s, "problem_ien", "the refusal names the missing problem"
    assert_equal before, newest(POV_FILE), "a refused Pov.add filed a V POV"
  end

  def test_add_files_the_diagnosis_against_its_problem
    refute_nil RpmsRpc::Patient.find(DFN), "DFN #{DFN} must exist on this disposable container's seed data"
    visit = open_visit!
    stamp = Time.now.utc.strftime("%H%M%S")
    problem = RpmsRpc::Problem.add(DFN, { icd_code: ICD, description: "SYNTH LIVE POV PROBLEM #{stamp}",
                                          location_ien: problem_location!, status: "Chronic" })
    assert problem[:success], "Problem.add answered #{problem.inspect}"

    result = RpmsRpc::Pov.add(DFN, visit, ICD, narrative: "SYNTH LIVE POV #{stamp}",
                                               modifiers: { problem_ien: problem[:ien], snomed_ct: SNOMED, primary: true })
    assert result[:success], "Pov.add answered #{result.inspect}"

    row = RpmsRpc::DdrFileman.gets_entry(file: POV_FILE, iens: "#{result[:ien]},", fields: ".01;.02;.03;.16", flags: "IE")
    flunk "DDR GETS on V POV #{result[:ien]} failed: #{row.inspect}" if row.nil? || row[:error]
    fields = row[:fields]
    assert_equal ICD, fields.dig(".01", :external), "V POV #{result[:ien]} is not diagnosis #{ICD}"
    assert_equal DFN.to_s, fields.dig(".02", :internal), "V POV #{result[:ien]} is not the patient's"
    assert_equal visit.to_s, fields.dig(".03", :internal), "V POV #{result[:ien]} is not on visit #{visit}"
    assert_equal problem[:ien].to_s, fields.dig(".16", :internal), "V POV #{result[:ien]} .16 is not the problem sent"
    puts "\n#{role}: V POV #{result[:ien]} on visit #{visit} filed against PROBLEM #{problem[:ien]}"
  end

  # Pov.delete (BGOVPOV DEL): the V POV is gone, the problem no longer reads
  # as used on a visit, so it can be deleted; another patient's DFN is
  # refused before anything is sent.
  def test_delete_removes_the_diagnosis_and_frees_its_problem
    visit = open_visit!
    stamp = Time.now.utc.strftime("%H%M%S")
    problem = RpmsRpc::Problem.add(DFN, { icd_code: ICD, description: "SYNTH LIVE POV DELETE #{stamp}",
                                          location_ien: problem_location!, status: "Chronic" })
    assert problem[:success], "Problem.add answered #{problem.inspect}"
    pov = RpmsRpc::Pov.add(DFN, visit, ICD, narrative: "SYNTH LIVE POV DELETE #{stamp}",
                                            modifiers: { problem_ien: problem[:ien], snomed_ct: SNOMED })
    assert pov[:success], "Pov.add answered #{pov.inspect}"
    assert RpmsRpc::Problem.integrated_entry(problem[:ien])[:used_as_pov], "the problem reads as used on the visit"

    assert_equal :wrong_patient, RpmsRpc::Pov.delete(DFN + 1, pov[:ien], problem_ien: problem[:ien])[:error]
    deleted = RpmsRpc::Pov.delete(DFN, pov[:ien], problem_ien: problem[:ien])
    assert deleted[:success], "Pov.delete answered #{deleted.inspect}"

    gone = RpmsRpc::DdrFileman.gets_entry(file: POV_FILE, iens: "#{pov[:ien]},", fields: ".01", flags: "I")
    assert gone.nil? || gone[:error] || gone[:fields].empty?, "V POV #{pov[:ien]} is still on file: #{gone.inspect}"
    refute_includes RpmsRpc::Pov.for_visit(visit).map { |row| row[:ien] }, pov[:ien]
    refute RpmsRpc::Problem.integrated_entry(problem[:ien])[:used_as_pov], "the problem still reads as used on a visit"
    assert_equal :not_found, RpmsRpc::Pov.delete(DFN, pov[:ien])[:error]
    assert RpmsRpc::Problem.delete(DFN, problem[:ien], reason: "Entered in error")[:success], "the freed problem could not be deleted"
    puts "\n#{role}: V POV #{pov[:ien]} on visit #{visit} deleted, PROBLEM #{problem[:ien]} freed and deleted"
  end

  private

  # A new ambulatory visit for the synthetic patient, at a time no other
  # spec uses.
  def open_visit!
    now = RpmsRpc::FilemanDateParser.parse_datetime(Array(client.call_rpc("ORWU DT", "NOW")).first.to_s)
    flunk "ORWU DT NOW did not yield a FileMan datetime" unless now
    at = RpmsRpc::FilemanDateParser.format_datetime(now - (rand(30..3000) * 86_400) - (rand(0..59) * 60))
    made = RpmsRpc::Encounter.create(DFN, location_ien: LOCATION_IEN, datetime: at, service_category: "A", create: 1)
    flunk "Encounter.create for DFN #{DFN} answered #{made.inspect}" unless made[:success]
    made[:visit_ien]
  end

  # The INSTITUTION the build's own problems are numbered under (.06).
  def problem_location!
    listed = RpmsRpc::DdrFileman.lister(file: PROBLEM_FILE, fields: ".06", flags: "IP", max: "1")
    flunk "DDR LISTER on PROBLEM failed: #{listed.inspect}" if listed.nil? || listed[:error]
    row = listed[:entries].first
    flunk "no PROBLEM on file to take a location from: is this the pinned image?" if row.nil?
    row[:pieces].first
  end

  def newest(file)
    listed = RpmsRpc::DdrFileman.lister(file: file, fields: ".01", flags: "IPB", max: "1", xref: "#")
    flunk "DDR LISTER on #{file} failed: #{listed.inspect}" if listed.nil? || listed[:error]
    listed[:entries].first&.dig(:ien).to_i
  end
end
