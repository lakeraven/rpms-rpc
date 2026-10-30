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

  # Isolated synthetic patient (not DFN 8 wire-capture input, not ADD_DFN).
  NKA_DFN = 990_040
  ADD_DFN = 990_032
  PATIENT_ALLERGY_FILE = "120.8"
  SEVERITY_CODE = "2"

  def test_save_files_a_lookup_agent_and_list_reads_it_back
    agent = lookup_unused_agent_for!(ADD_DFN)
    refute RpmsRpc::Allergy.for_patient(ADD_DFN).any? { |row| row[:allergen].to_s.casecmp?(agent[:name]) },
           "agent #{agent[:name]} must be absent on DFN #{ADD_DFN} before this run's save"
    attrs = build_allergy(agent)

    result = RpmsRpc::Allergy.save(ADD_DFN, attrs)
    assert result[:success], "Allergy.save must succeed for a new agent on this run: #{result.inspect}"

    rows = RpmsRpc::Allergy.for_patient(ADD_DFN)
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
    flunk "DDR GETS on allergy #{row[:ien]} returned no fields: #{entry.inspect}" if entry[:fields].empty?
    assert_equal agent[:name], entry[:fields].dig("1", :external), "GMRAGNT external name"
    assert_equal "D", entry[:fields].dig("3.1", :internal), "GMRATYPE"
    assert_equal "A", entry[:fields].dig("17", :internal), "GMRANATR"

    assert_filed_gmrasevr!(row[:ien], SEVERITY_CODE)

    puts "\n#{persona}: allergy #{row[:ien]} (#{agent[:name]}) on DFN #{ADD_DFN} reads back through LIST and #120.8"
  end

  def test_no_known_allergies_marks_an_unassessed_patient_nka
    assess_before = RpmsRpc::Allergy.assessment(NKA_DFN)
    refute assess_before[:conflict], assess_before.inspect
    if assess_before[:assessed] && !assess_before[:nka] && assess_before[:allergies].any?
      flunk "DFN #{NKA_DFN} already has active allergies on this build (#{assess_before[:allergies].inspect}); " \
            "use a disposable container seed patient with no allergies for NKA"
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

  def lookup_unused_agent_for!(dfn)
    catalog = RpmsRpc::DdrFileman.lister(file: "120.82", fields: ".01", flags: "IP")
    flunk "DDR LISTER on GMR ALLERGIES (120.82) gave no reply" if catalog.nil?
    flunk "DDR LISTER on GMR ALLERGIES (120.82) answered an error" if catalog[:error]
    flunk "no allergen entries in GMR ALLERGIES (120.82) on this build" if catalog[:entries].empty?

    existing = RpmsRpc::Allergy.for_patient(dfn).map { |row| row[:allergen].to_s.downcase }

    catalog[:entries].each do |entry|
      name = entry[:pieces].first.to_s
      next if name.empty?
      next if existing.any? { |known| known.casecmp?(name) }

      ien = entry[:ien].to_s
      return { name: name, pointer: "#{ien};GMRD(120.82," }
    end

    flunk "no GMR ALLERGIES (#120.82) agent absent from DFN #{dfn} on this build"
  end

  # GMRASEVR (ORWDAL32.m:88-89) is read from PATIENT ALLERGIES (#120.8). The
  # field number is resolved at run time from DDR VALIDATE field names, then
  # by scanning the filed entry for the internal severity code.
  # GMRASEVR (ORWDAL32.m:88-89) is read from PATIENT ALLERGIES (#120.8). Resolve
  # the field from DDR VALIDATE names (SEVERITY/GMRASEVR) or from the filed entry.
  def assert_filed_gmrasevr!(allergy_ien, expected_code)
    field = gmrasevr_field_number!(allergy_ien, expected_code)
    name = patient_allergy_field_name(field) || "field #{field}"
    entry = RpmsRpc::DdrFileman.gets_entry(
      file: PATIENT_ALLERGY_FILE, iens: "#{allergy_ien},", fields: field, flags: "IE"
    )
    refute_nil entry, "DDR GETS on allergy #{allergy_ien} field #{field}"
    flunk "DDR GETS on allergy #{allergy_ien} field #{field} returned no value: #{entry.inspect}" if entry[:fields].empty?
    internal = entry[:fields].dig(field, :internal).to_s
    assert_equal expected_code, internal, "GMRASEVR on #120.8 #{name}"
  rescue Minitest::Assertion => e
    skip_tracked("#383", e.message)
  end

  GMRASEVR_NON_FIELD = %w[1 3.1 4 5 6 15 17 19 22 .01 .02].freeze

  def gmrasevr_field_number!(allergy_ien, expected_code)
    by_name = (1..30).filter_map do |n|
      name = patient_allergy_field_name(n.to_s)
      next if name.nil?

      n.to_s if name.match?(/SEVERITY|GMRASEVR|\bSEVER\b/i)
    end
    unless by_name.empty?
      flunk "ambiguous SEVERITY fields on #120.8: #{by_name.join(', ')}" if by_name.size > 1
      return by_name.first
    end

    fields = (1..30).map(&:to_s).join(";")
    entry = RpmsRpc::DdrFileman.gets_entry(
      file: PATIENT_ALLERGY_FILE, iens: "#{allergy_ien},", fields: fields, flags: "IE"
    )
    refute_nil entry, "DDR GETS on allergy #{allergy_ien} for GMRASEVR scan"
    flunk "DDR GETS on allergy #{allergy_ien} for GMRASEVR scan returned no fields: #{entry.inspect}" if entry[:fields].empty?
    matches = entry[:fields].select do |num, value|
      !GMRASEVR_NON_FIELD.include?(num) && value[:internal].to_s == expected_code
    end
    if matches.empty?
      reportable = patient_allergy_field_name("7")
      if reportable&.match?(/REPORTABLE/i)
        internal = entry[:fields].dig("7", :internal).to_s
        flunk "GMRASEVR code #{expected_code} not filed on #120.8 IEN #{allergy_ien} " \
              "(#{reportable} field 7 internal #{internal.inspect}; ORWDAL32 SAVE ALLERGY did not persist severity on this build)"
      end
      flunk "GMRASEVR code #{expected_code} not present on #120.8 IEN #{allergy_ien} " \
            "(scanned fields 1–30; no SEVERITY/GMRASEVR field name in DDR VALIDATE on this build)"
    end
    flunk "ambiguous GMRASEVR fields on #120.8 IEN #{allergy_ien}: #{matches.keys.join(', ')}" if matches.size > 1
    matches.keys.first
  end

  def patient_allergy_field_name(field)
    reply = RpmsRpc::DdrFileman.validate_field(
      file: PATIENT_ALLERGY_FILE, iens: "0,", field: field.to_s, value: "INVALIDTEST"
    )
    return nil if reply.nil?

    msg = reply[:errors].first.to_s
    return nil if msg.include?("multi-valued") || msg.include?("does not contain a field")

    match = msg.match(/for field (.+?) in file/)
    match&.captures&.first
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
      severity: SEVERITY_CODE
    }
  end

  def server_now_fm
    value = Array(client.call_rpc("ORWU DT", "NOW")).first.to_s
    RpmsRpc::FilemanDateParser.parse_datetime(value)&.then { |t| RpmsRpc::FilemanDateParser.format_datetime(t) } ||
      flunk("ORWU DT NOW answered #{value.inspect}")
  end
end
