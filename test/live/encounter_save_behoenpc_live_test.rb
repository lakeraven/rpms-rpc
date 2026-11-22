# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/patient"
require "rpms_rpc/api/encounter"
require "rpms_rpc/fileman_date_parser"

# Encounter.save files an encounter through BEHOENPC SAVE (SAVE^BEHOENPC): a
# visit, its diagnosis (V POV, with the narrative and SNOMED concept), a CPT
# (V CPT), a health factor (V HEALTH FACTOR) and the primary provider
# (V PROVIDER), all on one visit, in one call (rpms-rpc#921; the RPC was
# proven by name here first, rpms-rpc#645, openrpms#1042).
#
# It is the stock route for an encounter write. ORWPCE SAVE, the CPRS name, is
# registered on the image to SAVE^CIAVCXPC, a routine the build does not carry,
# and repointing it to SAVE^ORWPCE files nothing (Visit Tracking, file 150.9,
# ships empty). docs/vuecentric-exit.md says so.
#
# This spec calls the wrapper, over the real CIA broker, as the run's persona,
# in CIAV VUECENTRIC (the context sign-on binds, which carries BEHOENPC SAVE
# and every read-back it uses), and checks the result against the V files
# with DDR: the oracle is the file, not the wrapper's own read-back.
#
# Piece 9 of a POV is its SNOMED concept, as VueCentric always sends it:
# POV^BEHOENPC maps it to its ICD with $$CONC^AUPNSICD and uses it as a
# subscript in PROBLST^BEHOENP2, which IRIS and a strict-null YottaDB refuse
# when it is empty (rpms-rpc#704). On the pinned build 35489007 (Depressive
# disorder) maps to F32.9 on both engines.
#
# The issue's acceptance (rpms-rpc#921) says a save creates no problem-list
# entry: rook's parity harness seeds visits with purposes of visit and must
# not add problems it did not ask for, because a problem changes CRS
# denominators. PROBLEM (#9000011) is therefore read before and after. Note
# what the routine says: POV^BEHOENPC calls $$PROBLST^BEHOENP2(SNO,FIVE)
# unconditionally, and PROBLST files a PROBLEM entry when the patient has no
# undeleted one with that concept (^AUPNPROB("APCT",DFN,SNO)), then links the
# visit to it. If this assertion fails on the pinned build, that is the
# finding, not a flaw in the spec: the route creates problems, and the
# decision belongs to the owner.
#
# WRITES against a disposable local container only.
class EncounterSaveBehoenpcLiveTest < LiveSpec::Test
  runs_as :provider
  writes!

  DFN = 990_053 # a synthetic seed patient; unused by other live specs
  CLINIC = "DEMO PRIMARY CARE"
  ICD = "F32.9"
  SNOMED = "35489007" # $$CONC^AUPNSICD maps it to F32.9
  PREFERRED_TERM = "Depressive disorder" # its preferred term
  CPT = "A0021"
  CATEGORY = "A"

  VISIT_FILE = "9000010"
  POV_FILE = "9000010.07"
  CPT_FILE = "9000010.18"
  HF_FILE = "9000010.23"
  PRV_FILE = "9000010.06"
  PROBLEM_FILE = "9000011"
  HF_TABLE = "9999999.64"
  CLINIC_FILE = "44"

  def test_one_call_files_a_visit_with_its_pov_cpt_health_factor_and_provider_and_no_problem
    assert_synthetic_patient!(DFN)
    loc = clinic_ien!
    hf = first_health_factor!
    duz = client.duz.to_s
    narrative = "SYNTH LIVE BEHOENPC #{role} #{Time.now.utc.strftime('%H%M%S')}"
    now = server_now
    at = Time.new(now.year, now.month, now.day, now.hour, now.min, 0)

    problems_before = problems_of(DFN)
    povs_before = iens(POV_FILE)

    result = RpmsRpc::Encounter.save(
      DFN,
      location_ien: loc, datetime: at, service_category: CATEGORY, provider_duz: duz,
      diagnoses: [ { icd: ICD, snomed: SNOMED, narrative: narrative, primary: true } ],
      procedures: [ { cpt: CPT } ],
      health_factors: [ { ien: hf } ]
    )
    assert result[:success], "Encounter.save answered #{result.inspect}"
    assert_equal "0", result[:raw], "BEHOENPC SAVE answers 0 when it files (BEHOENPC.m:5)"
    assert_equal [], result[:not_filed]

    # The visit the wrapper named is this patient's, at this clinic and category.
    visit = result[:visit_ien].to_s
    assert_match(/\A[1-9]\d*\z/, visit, "the result names no visit: #{result.inspect}")
    entry = RpmsRpc::DdrFileman.gets_entry(file: VISIT_FILE, iens: "#{visit},", fields: ".05;.07;.22", flags: "IE")
    flunk "DDR GETS on VISIT #{visit} failed: #{entry.inspect}" if entry.nil? || entry[:error]
    assert_equal DFN.to_s, entry.dig(:fields, ".05", :internal).to_s, "VISIT #{visit} .05 is not the patient sent"
    assert_equal CATEGORY, entry.dig(:fields, ".07", :internal).to_s, "VISIT #{visit} .07 is not the category sent"
    assert_equal loc.to_s, entry.dig(:fields, ".22", :internal).to_s, "VISIT #{visit} .22 is not the clinic sent"

    # The V POV the result names is new, on this visit, this diagnosis and
    # concept, with the narrative sent. The narrative is filed to PROVIDER
    # NARRATIVE (#9999999.27) with the concept's preferred-term description
    # id ("<text>|<id>", POV^BEHOENPC), and reads back as
    # "<preferred term> | <text>" (observed on the pinned build). The concept
    # is filed to SNOMED CT (1101).
    assert_equal 1, result[:diagnoses].size, result[:diagnoses].inspect
    pov_ien = result[:diagnoses].first[:ien].to_s
    refute_includes povs_before, pov_ien, "V POV #{pov_ien} was on file before this call"
    pov = fields_of(POV_FILE, pov_ien, ".01E;.02;.03;.04E;1101")
    assert_equal ICD, pov[".01"], "V POV #{pov_ien} is not diagnosis #{ICD}"
    assert_equal DFN.to_s, pov[".02"], "V POV #{pov_ien} is not the patient's"
    assert_equal visit, pov[".03"], "V POV #{pov_ien} is not on visit #{visit}"
    assert_equal "#{PREFERRED_TERM} | #{narrative}", pov[".04"], "V POV #{pov_ien} does not carry the narrative sent"
    assert_equal SNOMED, pov["1101"], "V POV #{pov_ien} is not SNOMED concept #{SNOMED}"

    assert_equal 1, result[:procedures].size, result[:procedures].inspect
    cpt_ien = result[:procedures].first[:ien].to_s
    cpt = fields_of(CPT_FILE, cpt_ien, ".01E;.02;.03")
    assert_equal [ CPT, DFN.to_s, visit ], [ cpt[".01"], cpt[".02"], cpt[".03"] ],
                 "V CPT #{cpt_ien} is not the code and patient sent, on visit #{visit}"

    assert_equal 1, result[:health_factors].size, result[:health_factors].inspect
    hf_ien = result[:health_factors].first[:ien].to_s
    hf_row = fields_of(HF_FILE, hf_ien, ".01;.02;.03")
    assert_equal [ hf.to_s, DFN.to_s, visit ], [ hf_row[".01"], hf_row[".02"], hf_row[".03"] ],
                 "V HEALTH FACTOR #{hf_ien} is not the factor and patient sent, on visit #{visit}"

    # "PRV" without "+" edits the user's existing row on the visit, so it is
    # found, not new. Every store stamps 1218 DATE/TIME LAST MODIFIED with
    # $$NOW^XLFDT (STORE^BEHOENPC), so this call's store is the one stamped at
    # or after `now`.
    assert_equal duz.to_i, result[:provider][:duz], "the result names the primary provider sent: #{result[:provider].inspect}"
    assert result[:provider][:primary], "the result marks the provider primary: #{result[:provider].inspect}"
    prv = rows(PRV_FILE, ".01;.02;.03;.04;1218").find { |r| r[2] == visit && r[0] == duz }
    refute_nil prv, "no V PROVIDER for DUZ #{duz} on visit #{visit}"
    assert_equal [ DFN.to_s, "P" ], [ prv[1], prv[3] ], "V PROVIDER #{duz} on visit #{visit} is not the patient's primary provider"
    stamped = RpmsRpc::FilemanDateParser.parse_datetime(prv[4])
    assert stamped && stamped >= now, "V PROVIDER #{duz} on visit #{visit} was not stored by this call (1218 #{prv[4].inspect}, call at #{now})"

    # And no problem-list entry is created (rpms-rpc#921 "Done when").
    problems_after = problems_of(DFN)
    added = problems_after - problems_before
    assert_empty added,
                 "Encounter.save added PROBLEM entries for DFN #{DFN}: #{added.inspect} " \
                 "(PROBLST^BEHOENP2 files one when the patient has no undeleted problem with concept #{SNOMED})"

    puts "\n#{role}: Encounter.save filed visit #{visit} on DFN #{DFN} with V POV #{pov_ien}, V CPT #{cpt_ien}, V HF #{hf_ien} and V PROVIDER #{duz}; problems unchanged (#{problems_after.size})"
  end

  def test_a_diagnosis_without_a_snomed_concept_is_refused_and_nothing_is_filed
    assert_synthetic_patient!(DFN)
    loc = clinic_ien!
    duz = client.duz.to_s
    now = server_now
    at = Time.new(now.year, now.month, now.day, now.hour, now.min, 0)
    povs_before = iens(POV_FILE)
    problems_before = problems_of(DFN)

    result = RpmsRpc::Encounter.save(
      DFN,
      location_ien: loc, datetime: at, service_category: CATEGORY, provider_duz: duz,
      diagnoses: [ { icd: ICD, snomed: nil, narrative: "SYNTH LIVE NO SNOMED #{role}", primary: true } ]
    )

    refute result[:success], "a diagnosis with no SNOMED concept must be refused: #{result.inspect}"
    assert_equal :missing_snomed, result[:error]
    assert_nil result[:raw], "nothing was sent, so nothing came back"
    assert_equal [ ICD ], result[:not_filed].select { |e| e[:kind] == :diagnosis }.map { |e| e[:icd] }
    assert_equal povs_before, iens(POV_FILE), "a refused save filed a V POV"
    assert_equal problems_before, problems_of(DFN), "a refused save changed the problem list"
  end

  private

  # The patient's PROBLEM (#9000011) entries as [ien, snomed, deleted] rows,
  # read from the file with DDR, independent of the problem-list RPCs.
  def problems_of(dfn)
    entries(PROBLEM_FILE, ".02;80001;2.02").select { |e| e[:pieces][0].to_s == dfn.to_s }
                                           .map { |e| [ e[:ien], e[:pieces][1].to_s, e[:pieces][2].to_s ] }
                                           .sort
  end

  # One V file entry's fields, keyed by field number, internal (or external
  # for a field named with E), as strings.
  def fields_of(file, ien, fields)
    entry = RpmsRpc::DdrFileman.gets_entry(file: file, iens: "#{ien},", fields: fields, flags: "IE")
    flunk "DDR GETS on #{file} #{ien} failed: #{entry.inspect}" if entry.nil? || entry[:error]
    externals = fields.split(";").select { |f| f.end_with?("E") }.map { |f| f.delete_suffix("E") }
    entry[:fields].to_h { |number, f| [ number, (externals.include?(number) ? f[:external] : f[:internal]).to_s ] }
  end

  # Every row of a V file as [pieces...] in the order of `fields`, leaving out
  # the IENs in `except`. The container is fresh, so the files are small.
  def rows(file, fields, except: [])
    entries(file, fields).reject { |e| except.include?(e[:ien]) }.map { |e| e[:pieces].map(&:to_s) }
  end

  def iens(file) = entries(file, ".01").map { |e| e[:ien] }

  def entries(file, fields)
    listed = RpmsRpc::DdrFileman.lister(file: file, fields: fields, flags: "IP", max: "*")
    flunk "DDR LISTER on #{file} failed: #{listed.inspect}" if listed.nil? || listed[:error]
    listed[:entries]
  end

  def clinic_ien!
    listed = RpmsRpc::DdrFileman.lister(file: CLINIC_FILE, fields: ".01", flags: "IP", from: CLINIC[0..-2], part: CLINIC, max: "1")
    flunk "DDR LISTER on HOSPITAL LOCATION failed: #{listed.inspect}" if listed.nil? || listed[:error]
    row = listed[:entries].find { |e| e[:pieces].first == CLINIC }
    flunk "no #{CLINIC} in HOSPITAL LOCATION (#44): the build seeds it (SEEDCLIN); is this the pinned image?" if row.nil?
    row[:ien]
  end

  def first_health_factor!
    listed = RpmsRpc::DdrFileman.lister(file: HF_TABLE, fields: ".01", flags: "IP", max: "1")
    flunk "DDR LISTER on HEALTH FACTORS failed: #{listed.inspect}" if listed.nil? || listed[:error]
    row = listed[:entries].first
    flunk "no entry in HEALTH FACTORS (#{HF_TABLE})" if row.nil?
    row[:ien]
  end

  def assert_synthetic_patient!(dfn)
    refute_nil RpmsRpc::Patient.find(dfn), "DFN #{dfn} must exist on this disposable container's seed data"
  end

  # The server's now, to the second.
  def server_now
    value = Array(client.call_rpc("ORWU DT", "NOW")).first.to_s
    RpmsRpc::FilemanDateParser.parse_datetime(value) || flunk("ORWU DT NOW did not yield a FileMan datetime: #{value.inspect}")
  end
end
