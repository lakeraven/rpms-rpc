# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/patient"
require "rpms_rpc/fileman_date_parser"

# BEHOENPC SAVE (SAVE^BEHOENPC) files an encounter: a visit, its diagnosis
# (V POV, with the narrative), a CPT (V CPT), a health factor (V HEALTH
# FACTOR) and the primary provider (V PROVIDER), all on one visit, in one call
# (rpms-rpc#645, rpms-ops#1042 and its build-level test
# test/encounter_save_build_level.sh).
#
# It is the stock route for an encounter write. ORWPCE SAVE, the CPRS name, is
# registered on the image to SAVE^CIAVCXPC, a routine the build does not carry,
# and repointing it to SAVE^ORWPCE files nothing (Visit Tracking, file 150.9,
# ships empty). docs/vuecentric-exit.md says so.
#
# The gem has no wrapper for it yet: this spec proves what the build does, over
# the real CIA broker, as the run's persona, in CIAV VUECENTRIC (the context
# sign-on binds, which carries BEHOENPC SAVE). It calls the RPC by name and
# reads every row back with DDR.
#
# The list is the piece layout BEHOENPC.m documents and the build-level test
# sends (SAVE^BEHOENPC: PCC(n) = "TYPE^CODE^...", "+" adds, "-" deletes):
#   HDR^0^^<loc>;<date>;<category>   VST^DT^<date>   VST^PT^<dfn>
#   VST^HL^<loc>   VST^VC^<category>   PRV^<duz>^^^^1 (primary)
#   POV+^<icd>^^^^1^^^^<narrative>   CPT+^<code>   HF+^<ien>^^^^<duz>
# P2 and P3 are "not used (but required)" (BEHOENPC.m:6-8); the build-level
# test sends 0 and the location, and so does this spec.
#
# WRITES against a disposable local container only.
class EncounterSaveBehoenpcLiveTest < LiveSpec::Test
  writes!

  DFN = 990_053 # a synthetic seed patient; unused by other live specs
  CLINIC = "DEMO PRIMARY CARE"
  ICD = "F32.9"
  CPT = "A0021"
  CATEGORY = "A"

  VISIT_FILE = "9000010"
  POV_FILE = "9000010.07"
  CPT_FILE = "9000010.18"
  HF_FILE = "9000010.23"
  PRV_FILE = "9000010.06"
  HF_TABLE = "9999999.64"
  CLINIC_FILE = "44"

  def test_one_call_files_a_visit_with_its_pov_cpt_health_factor_and_provider
    assert_synthetic_patient!(DFN)
    loc = clinic_ien!
    hf = first_health_factor!
    duz = client.duz.to_s
    narrative = "SYNTH LIVE BEHOENPC #{persona} #{Time.now.utc.strftime('%H%M%S')}"
    now = server_now
    when_fm = RpmsRpc::FilemanDateParser.format_datetime(Time.new(now.year, now.month, now.day, now.hour, now.min, 0))

    pcc = {
      1 => "HDR^0^^#{loc};#{when_fm};#{CATEGORY}",
      2 => "VST^DT^#{when_fm}",
      3 => "VST^PT^#{DFN}",
      4 => "VST^HL^#{loc}",
      5 => "VST^VC^#{CATEGORY}",
      6 => "PRV^#{duz}^^^^1",
      7 => "POV+^#{ICD}^^^^1^^^^#{narrative}",
      8 => "CPT+^#{CPT}",
      9 => "HF+^#{hf}^^^^#{duz}"
    }

    before_cpt = iens(CPT_FILE)
    before_hf = iens(HF_FILE)
    reply = Array(client.call_rpc("BEHOENPC SAVE", pcc, "0", loc.to_s)).map(&:to_s)
    assert_equal [ "0" ], reply, "BEHOENPC SAVE answers 0 when it files (BEHOENPC.m:5); it answered #{reply.inspect}"

    # The narrative is filed to PROVIDER NARRATIVE (#9999999.27) and reads back
    # with a leading "*" (observed on the pinned build).
    pov = rows(POV_FILE, ".01E;.02;.03;.04E").find { |r| r[1] == DFN.to_s && r[3].delete_prefix("*") == narrative }
    refute_nil pov, "no V POV on DFN #{DFN} carries the narrative sent (#{narrative.inspect})"
    visit = pov[2]
    assert_match(/\A\d+\z/, visit, "the V POV row names no visit: #{pov.inspect}")
    assert_equal ICD, pov[0], "the V POV with the narrative sent is not diagnosis #{ICD}"

    entry = RpmsRpc::DdrFileman.gets_entry(file: VISIT_FILE, iens: "#{visit},", fields: ".05;.07;.22", flags: "IE")
    flunk "DDR GETS on VISIT #{visit} failed: #{entry.inspect}" if entry.nil? || entry[:error]
    assert_equal DFN.to_s, entry.dig(:fields, ".05", :internal).to_s, "VISIT #{visit} .05 is not the patient sent"
    assert_equal CATEGORY, entry.dig(:fields, ".07", :internal).to_s, "VISIT #{visit} .07 is not the category sent"
    assert_equal loc.to_s, entry.dig(:fields, ".22", :internal).to_s, "VISIT #{visit} .22 is not the clinic sent"

    # A rerun on the same day and clinic files onto the same visit (FNDVIS^BEHOENCX
    # finds it). "CPT+" and "HF+" always add a row (STORE^BEHOENPC: ADD sets IEN "+1"),
    # so the rows this call filed are the ones whose IEN was not there before it.
    cpt = rows(CPT_FILE, ".01E;.02;.03", except: before_cpt).find { |r| r[2] == visit }
    refute_nil cpt, "BEHOENPC SAVE filed no new V CPT on visit #{visit}"
    assert_equal [ CPT, DFN.to_s ], cpt[0, 2], "the new V CPT on visit #{visit} is not the code and patient sent"

    hf_row = rows(HF_FILE, ".01;.02;.03", except: before_hf).find { |r| r[2] == visit }
    refute_nil hf_row, "BEHOENPC SAVE filed no new V HEALTH FACTOR on visit #{visit}"
    assert_equal [ hf.to_s, DFN.to_s ], hf_row[0, 2], "the new V HEALTH FACTOR on visit #{visit} is not the factor and patient sent"

    # "PRV" without "+" edits the user's existing row on the visit, so it is found, not
    # new. Every store stamps 1218 DATE/TIME LAST MODIFIED with $$NOW^XLFDT
    # (STORE^BEHOENPC), so this call's store is the one stamped at or after `now`.

    prv = rows(PRV_FILE, ".01;.02;.03;.04;1218").find { |r| r[2] == visit && r[0] == duz }
    refute_nil prv, "no V PROVIDER for DUZ #{duz} on visit #{visit}"
    assert_equal [ DFN.to_s, "P" ], [ prv[1], prv[3] ], "V PROVIDER #{duz} on visit #{visit} is not the patient's primary provider"
    stamped = RpmsRpc::FilemanDateParser.parse_datetime(prv[4])
    assert stamped && stamped >= now, "V PROVIDER #{duz} on visit #{visit} was not stored by this call (1218 #{prv[4].inspect}, call at #{now})"

    puts "\n#{persona}: BEHOENPC SAVE filed visit #{visit} on DFN #{DFN} with V POV, V CPT, V HF and V PROVIDER"
  end

  private

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
