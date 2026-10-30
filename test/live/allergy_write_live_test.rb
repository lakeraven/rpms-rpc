# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/allergy"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/fileman_date_parser"

# RpmsRpc::Allergy.save and .no_known_allergies over ORWDAL32 SAVE ALLERGY
# (rpms-rpc#453), read back through .assessment / .for_patient (ORQQAL LIST)
# and GMRA (#120.8) where LIST omits type and nature. It WRITES against a
# disposable local container only.
class AllergyWriteLiveTest < LiveSpec::Test
  writes!

  # Synthetic registration patient with no allergies on a fresh container (issue #383).
  NKA_DFN = 8
  # Seed patient no other live spec asserts allergy contents for.
  ADD_DFN = 990_032
  PATIENT_ALLERGY_FILE = "120.8"

  def test_save_files_a_lookup_agent_and_list_reads_it_back
    agent = lookup_agent!
    before = RpmsRpc::Allergy.for_patient(ADD_DFN)
    attrs = build_allergy(agent)

    result = RpmsRpc::Allergy.save(ADD_DFN, attrs)
    unless result[:success]
      assert_equal :duplicate, result[:error], "save answered #{result.inspect}"
    end

    rows = RpmsRpc::Allergy.for_patient(ADD_DFN)
    assert_operator rows.size, :>=, before.size, "ORQQAL LIST dropped rows after save"
    row = rows.find { |r| r[:allergen].to_s.casecmp?(agent[:name]) }
    refute_nil row, "expected agent #{agent[:name]} on DFN #{ADD_DFN}, got #{rows.inspect}"

    assess = RpmsRpc::Allergy.assessment(ADD_DFN)
    assert assess[:assessed], "patient with a filed allergy should read assessed"
    refute assess[:nka]
    refute assess[:conflict], assess.inspect

    entry = RpmsRpc::DdrFileman.gets_entry(
      file: PATIENT_ALLERGY_FILE, iens: "#{row[:ien]},", fields: "1;3.1;17", flags: "IE"
    )
    refute_nil entry, "DDR GETS on allergy #{row[:ien]}"
    refute entry[:error], entry.inspect
    assert_equal agent[:name], entry[:fields].dig("1", :external), "GMRAGNT external name"
    assert_equal "D", entry[:fields].dig("3.1", :internal), "GMRATYPE"
    assert_equal "A", entry[:fields].dig("17", :internal), "GMRANATR"
    assert_equal "2", row[:severity], "ORQQAL severity when GMRASEVR is filed" if row[:severity]

    puts "\n#{persona}: allergy #{row[:ien]} (#{agent[:name]}) on DFN #{ADD_DFN} reads back through LIST and #120.8"
  end

  def test_no_known_allergies_marks_an_unassessed_patient_nka
    assess_before = RpmsRpc::Allergy.assessment(NKA_DFN)
    refute assess_before[:conflict], assess_before.inspect
    if assess_before[:assessed] && !assess_before[:nka] && assess_before[:allergies].any?
      result = RpmsRpc::Allergy.no_known_allergies(NKA_DFN)
      refute result[:success], "NKA on a patient with active allergies must not succeed quietly"
      assert_equal :active_allergies, result[:error], result.inspect
      return
    end

    result = RpmsRpc::Allergy.no_known_allergies(NKA_DFN)
    assert result[:success], "no_known_allergies answered #{result.inspect}"

    assess = RpmsRpc::Allergy.assessment(NKA_DFN)
    refute assess[:conflict], assess.inspect
    assert assess[:assessed], assess.inspect
    assert assess[:nka], "assessment must read NKA after no_known_allergies"
    assert_empty assess[:allergies]

    rerun = RpmsRpc::Allergy.no_known_allergies(NKA_DFN)
    assert rerun[:success], "already-NKA should stay success (GMRAGUI1 NKA^): #{rerun.inspect}"

    puts "\n#{persona}: DFN #{NKA_DFN} reads assessed NKA after no_known_allergies"
  end

  private

  # First GMR ALLERGIES (#120.82) entry on the build — agent and pointer for GMRAGNT.
  def lookup_agent!
    listed = RpmsRpc::DdrFileman.lister(file: "120.82", fields: ".01", flags: "IP", max: "1")
    flunk "DDR LISTER on GMR ALLERGIES (120.82) gave no reply" if listed.nil?
    flunk "DDR LISTER on GMR ALLERGIES (120.82) answered an error" if listed[:error]
    entry = listed[:entries].first
    flunk "no allergen entries in GMR ALLERGIES (120.82) on this build" if entry.nil?

    ien = entry[:ien].to_s
    name = entry[:pieces].first.to_s
    { name: name, pointer: "#{ien};GMRD(120.82," }
  end

  def build_allergy(agent)
    now = server_now_fm
    {
      agent: agent[:name],
      agent_pointer: agent[:pointer],
      type: "D",
      nature: "A",
      originator: client.duz,
      originated_at: now,
      observed_or_historical: "o",
      severity: "2"
    }
  end

  def server_now_fm
    value = Array(client.call_rpc("ORWU DT", "NOW")).first.to_s
    RpmsRpc::FilemanDateParser.parse_datetime(value)&.then { |t| RpmsRpc::FilemanDateParser.format_datetime(t) } ||
      flunk("ORWU DT NOW answered #{value.inspect}")
  end
end
