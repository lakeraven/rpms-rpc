# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/patient"
require "rpms_rpc/api/encounter"
require "rpms_rpc/api/pov"
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
# POV^BEHOENPC also calls $$PROBLST^BEHOENP2(SNO,FIVE) unconditionally
# (BEHOENPC.m:163 on bcer-9.0-20261119-f67498c-ydb): it reuses the patient's
# undeleted PROBLEM (#9000011) entry with that concept (^AUPNPROB("APCT",
# DFN,SNO)) or files a new one, links the visit to it, and stores it in the
# V POV's .16. The owner accepted this (rpms-rpc#921, 2026-11-22): the
# wrapper reports each diagnosis's problem rather than avoiding the link.
# So the first save, on a patient with no problem for the concept, files a
# problem the result names, carrying the concept in 80001; a second save of
# the same concept names that same problem and files no other.
#
# WRITES against a disposable local container only.
class EncounterSaveBehoenpcLiveTest < LiveSpec::Test
  runs_as :provider
  writes!

  # Synthetic seed patients no other live spec names, in order of preference.
  # Scenario 1 takes the first that exists and holds no undeleted problem for
  # SNOMED, so a rerun on a container where an earlier run filed that problem
  # moves to the next patient instead of failing its precondition.
  CANDIDATE_DFNS = [ 990_053, 990_047, 990_042, 990_041, 990_039, 990_038 ].freeze
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

  def test_one_call_files_a_visit_with_its_pov_cpt_health_factor_and_provider_linked_to_a_new_problem
    dfn = dfn_without_problem_for!(SNOMED)
    loc = clinic_ien!
    hf = first_health_factor!
    duz = client.duz.to_s
    narrative = "SYNTH LIVE BEHOENPC #{role} #{Time.now.utc.strftime('%H%M%S')}"
    now = server_now
    at = Time.new(now.year, now.month, now.day, now.hour, now.min, 0)

    problems_before = problems_of(dfn)
    povs_before = iens(POV_FILE)

    result = RpmsRpc::Encounter.save(
      dfn,
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
    assert_equal dfn.to_s, entry.dig(:fields, ".05", :internal).to_s, "VISIT #{visit} .05 is not the patient sent"
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
    pov = fields_of(POV_FILE, pov_ien, ".01;.02;.03;.04;1101", external: %w[.01 .04])
    assert_equal ICD, pov[".01"], "V POV #{pov_ien} is not diagnosis #{ICD}"
    assert_equal dfn.to_s, pov[".02"], "V POV #{pov_ien} is not the patient's"
    assert_equal visit, pov[".03"], "V POV #{pov_ien} is not on visit #{visit}"
    assert_equal "#{PREFERRED_TERM} | #{narrative}", pov[".04"], "V POV #{pov_ien} does not carry the narrative sent"
    assert_equal SNOMED, pov["1101"], "V POV #{pov_ien} is not SNOMED concept #{SNOMED}"

    # BGOVPOV GET carries the concept's description in piece 21, not its ID
    # (rpms-rpc#927): Pov.for_visit names it snomed_description.
    got = RpmsRpc::Pov.for_visit(visit).find { |row| row[:ien].to_s == pov_ien }
    refute_nil got, "Pov.for_visit(#{visit}) does not list V POV #{pov_ien}"
    assert_equal PREFERRED_TERM, got[:snomed_description], "BGOVPOV GET piece 21 for V POV #{pov_ien}"

    assert_equal 1, result[:procedures].size, result[:procedures].inspect
    cpt_ien = result[:procedures].first[:ien].to_s
    cpt = fields_of(CPT_FILE, cpt_ien, ".01;.02;.03", external: %w[.01])
    assert_equal [ CPT, dfn.to_s, visit ], [ cpt[".01"], cpt[".02"], cpt[".03"] ],
                 "V CPT #{cpt_ien} is not the code and patient sent, on visit #{visit}"

    assert_equal 1, result[:health_factors].size, result[:health_factors].inspect
    hf_ien = result[:health_factors].first[:ien].to_s
    hf_row = fields_of(HF_FILE, hf_ien, ".01;.02;.03")
    assert_equal [ hf.to_s, dfn.to_s, visit ], [ hf_row[".01"], hf_row[".02"], hf_row[".03"] ],
                 "V HEALTH FACTOR #{hf_ien} is not the factor and patient sent, on visit #{visit}"

    # "PRV" without "+" edits the user's existing row on the visit, so it is
    # found, not new. Every store stamps 1218 DATE/TIME LAST MODIFIED with
    # $$NOW^XLFDT (STORE^BEHOENPC), so this call's store is the one stamped at
    # or after `now`.
    assert_equal duz.to_i, result[:provider][:duz], "the result names the primary provider sent: #{result[:provider].inspect}"
    assert result[:provider][:primary], "the result marks the provider primary: #{result[:provider].inspect}"
    prv = rows(PRV_FILE, ".01;.02;.03;.04;1218").find { |r| r[2] == visit && r[0] == duz }
    refute_nil prv, "no V PROVIDER for DUZ #{duz} on visit #{visit}"
    assert_equal [ dfn.to_s, "P" ], [ prv[1], prv[3] ], "V PROVIDER #{duz} on visit #{visit} is not the patient's primary provider"
    stamped = RpmsRpc::FilemanDateParser.parse_datetime(prv[4])
    assert stamped && stamped >= now, "V PROVIDER #{duz} on visit #{visit} was not stored by this call (1218 #{prv[4].inspect}, call at #{now})"

    # The diagnosis is linked to the problem list: the patient held no problem
    # for the concept, so PROBLST^BEHOENP2 filed one. The result names it, it
    # is this patient's, undeleted, carries the concept (80001), and the
    # V POV's .16 points at it (rpms-rpc#921 "Done when", scenario 1).
    problem_ien = result[:diagnoses].first[:problem_ien].to_s
    assert_match(/\A[1-9]\d*\z/, problem_ien, "the result names no problem for the diagnosis: #{result[:diagnoses].inspect}")
    refute_includes problems_before.map(&:first), problem_ien, "PROBLEM #{problem_ien} was on file before this call"
    problem = fields_of(PROBLEM_FILE, problem_ien, ".02;80001;2.02")
    assert_equal dfn.to_s, problem[".02"], "PROBLEM #{problem_ien} is not DFN #{dfn}'s"
    assert_equal SNOMED, problem["80001"], "PROBLEM #{problem_ien} does not carry concept #{SNOMED}"
    assert_equal "", problem["2.02"], "PROBLEM #{problem_ien} is deleted"
    pov16 = fields_of(POV_FILE, pov_ien, ".16")
    assert_equal problem_ien, pov16[".16"], "V POV #{pov_ien} .16 does not point at the problem the result names"
    problems_after = problems_of(dfn)
    assert_equal problems_before.size + 1, problems_after.size,
                 "exactly one problem is filed for the one diagnosis: before #{problems_before.inspect}, after #{problems_after.inspect}"

    # Scenario 2 (rpms-rpc#921 "Done when"): the patient now holds an undeleted
    # problem for the concept, so a second save of the same diagnosis reuses
    # it: PROBLST^BEHOENP2 answers the existing problem, the new V POV's .16
    # points at it, and no other problem is filed. Done here, after the first
    # save, because Minitest runs methods in random order and the first
    # scenario needs the concept absent.
    povs_before_reuse = iens(POV_FILE)
    reuse = RpmsRpc::Encounter.save(
      dfn,
      location_ien: loc, datetime: at, service_category: CATEGORY, provider_duz: duz,
      diagnoses: [ { icd: ICD, snomed: SNOMED, narrative: "SYNTH LIVE REUSE #{role} #{Time.now.utc.strftime('%H%M%S')}", primary: true } ]
    )
    assert reuse[:success], "the second Encounter.save answered #{reuse.inspect}"
    reuse_pov = reuse[:diagnoses].first[:ien].to_s
    refute_includes povs_before_reuse, reuse_pov, "V POV #{reuse_pov} was on file before the second save (\"+\" always adds a row)"
    refute_equal pov_ien, reuse_pov, "the second save must file its own V POV"
    assert_equal problem_ien, reuse[:diagnoses].first[:problem_ien].to_s,
                 "the second save names the problem already held for concept #{SNOMED}: #{reuse[:diagnoses].inspect}"
    assert_equal problem_ien, fields_of(POV_FILE, reuse_pov, ".16")[".16"], "V POV #{reuse_pov} .16 does not point at the existing problem"
    assert_equal problems_after, problems_of(dfn), "a diagnosis whose concept is already on the problem list filed another problem"

    puts "\n#{role}: Encounter.save filed visit #{visit} on DFN #{dfn} with V POV #{pov_ien} (problem #{problem_ien}, new), " \
         "V CPT #{cpt_ien}, V HF #{hf_ien} and V PROVIDER #{duz}; a second save filed V POV #{reuse_pov} against the same problem"
  end

  def test_a_diagnosis_without_a_snomed_concept_is_refused_and_nothing_is_filed
    dfn = synthetic_dfn!
    loc = clinic_ien!
    duz = client.duz.to_s
    now = server_now
    at = Time.new(now.year, now.month, now.day, now.hour, now.min, 0)
    povs_before = iens(POV_FILE)
    problems_before = problems_of(dfn)

    result = RpmsRpc::Encounter.save(
      dfn,
      location_ien: loc, datetime: at, service_category: CATEGORY, provider_duz: duz,
      diagnoses: [ { icd: ICD, snomed: nil, narrative: "SYNTH LIVE NO SNOMED #{role}", primary: true } ]
    )

    refute result[:success], "a diagnosis with no SNOMED concept must be refused: #{result.inspect}"
    assert_equal :missing_snomed, result[:error]
    assert_nil result[:raw], "nothing was sent, so nothing came back"
    assert_equal [ ICD ], result[:not_filed].select { |e| e[:kind] == :diagnosis }.map { |e| e[:icd] }
    assert_equal povs_before, iens(POV_FILE), "a refused save filed a V POV"
    assert_equal problems_before, problems_of(dfn), "a refused save changed the problem list"
  end

  private

  # The patient's PROBLEM (#9000011) entries as [ien, snomed, deleted] rows,
  # read from the file with DDR, independent of the problem-list RPCs.
  def problems_of(dfn)
    entries(PROBLEM_FILE, ".02;80001;2.02").select { |e| e[:pieces][0].to_s == dfn.to_s }
                                           .map { |e| [ e[:ien], e[:pieces][1].to_s, e[:pieces][2].to_s ] }
                                           .sort
  end

  # One file entry's fields, keyed by field number, as strings: the internal
  # value, or the external one for the numbers in `external`. DDR GETS ENTRY
  # DATA takes plain field numbers (an "E" suffix is LIST^DIC's FIELDS
  # syntax, not GETS^DIQ's); flags "IE" answer both forms for every field.
  def fields_of(file, ien, fields, external: [])
    entry = RpmsRpc::DdrFileman.gets_entry(file: file, iens: "#{ien},", fields: fields, flags: "IE")
    flunk "DDR GETS on #{file} #{ien} failed: #{entry.inspect}" if entry.nil? || entry[:error]
    entry[:fields].to_h { |number, f| [ number, (external.include?(number) ? f[:external] : f[:internal]).to_s ] }
  end

  # The first candidate patient on this container's seed data that holds no
  # undeleted problem for `snomed`, so scenario 1 can witness the problem the
  # save files; or a failure naming what every candidate holds.
  def dfn_without_problem_for!(snomed)
    held = {}
    CANDIDATE_DFNS.each do |dfn|
      next if RpmsRpc::Patient.find(dfn).nil?

      rows = problems_of(dfn).select { |_ien, concept, deleted| concept == snomed && deleted.empty? }
      return dfn if rows.empty?

      held[dfn] = rows.map(&:first)
    end
    flunk "every candidate synthetic patient already holds an undeleted problem for concept #{snomed} " \
          "(#{held.inspect}): this scenario needs a fresh disposable container"
  end

  def synthetic_dfn!
    dfn = CANDIDATE_DFNS.find { |candidate| RpmsRpc::Patient.find(candidate) }
    flunk "none of #{CANDIDATE_DFNS.inspect} exists on this disposable container's seed data" if dfn.nil?
    dfn
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

  # The server's now, to the second.
  def server_now
    value = Array(client.call_rpc("ORWU DT", "NOW")).first.to_s
    RpmsRpc::FilemanDateParser.parse_datetime(value) || flunk("ORWU DT NOW did not yield a FileMan datetime: #{value.inspect}")
  end
end
