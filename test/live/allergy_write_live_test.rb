# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/allergy"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/fileman_date_parser"

# RpmsRpc::Allergy.save and .no_known_allergies over ORWDAL32 SAVE ALLERGY
# (rpms-rpc#453), read back through .assessment / .for_patient (ORQQAL LIST)
# and GMRA (#120.8) where LIST omits type and nature. Observed severity is
# filed on ADVERSE REACTION REPORTING (#120.85) via ADVERSE^GMRAOR7
# (GMRAGUI1.m UPDATE), not on #120.8. It WRITES against a disposable local
# container only.
class AllergyWriteLiveTest < LiveSpec::Test
  writes!

  # Isolated synthetic patient (not DFN 8 wire-capture input, not ADD_DFN).
  NKA_DFN = 990_040
  ADD_DFN = 990_032
  PATIENT_ALLERGY_FILE = "120.8"
  ADVERSE_REACTION_FILE = "120.85"
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

    assert_filed_adverse_severity!(ADD_DFN, row[:ien], SEVERITY_CODE)

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

  # GMRASEVR for GMRAOBHX "o" is filed on #120.85 (field SEVERITY, DD 0;14 /
  # 14.5 on this build) by ADVERSE^GMRAOR7 (GMRAGUI1.m UPDATE). Entries are
  # indexed on the related #120.8 IEN (^GMR(120.85,"C",GMRAIEN,)).
  def assert_filed_adverse_severity!(dfn, allergy_ien, expected_code)
    listed = RpmsRpc::DdrFileman.lister(
      file: ADVERSE_REACTION_FILE, fields: "@", flags: "IP", xref: "C", part: allergy_ien.to_s
    )
    flunk "DDR LISTER on ADVERSE REACTION REPORTING (#120.85) gave no reply" if listed.nil?
    flunk "DDR LISTER on ADVERSE REACTION REPORTING (#120.85) answered an error" if listed[:error]
    entries = listed[:entries]
    if entries.empty?
      flunk "no #120.85 ADVERSE REACTION REPORTING entry for allergy IEN #{allergy_ien} on DFN #{dfn} " \
            "(observed save should call ADVERSE^GMRAOR7; severity is not on #120.8)"
    end
    if entries.size > 1
      flunk "ambiguous #120.85 entries for allergy IEN #{allergy_ien}: #{entries.map { |e| e[:ien] }.join(', ')}"
    end

    report_ien = entries.first[:ien]
    related_field = adverse_reaction_related_field!
    severity_field = adverse_reaction_severity_field!
    fields = [ related_field, severity_field, ".02" ].uniq.join(";")
    entry = RpmsRpc::DdrFileman.gets_entry(
      file: ADVERSE_REACTION_FILE, iens: "#{report_ien},", fields: fields, flags: "IE"
    )
    refute_nil entry, "DDR GETS on #120.85 entry #{report_ien}"
    flunk "DDR GETS on #120.85 entry #{report_ien} returned no fields: #{entry.inspect}" if entry[:fields].empty?

    patient = entry[:fields].dig(".02", :internal).to_s
    assert_equal dfn.to_s, patient, "PATIENT on #120.85 entry #{report_ien}"

    related = entry[:fields].dig(related_field, :internal).to_s
    assert_equal allergy_ien.to_s, related,
                 "RELATED REACTION on #120.85 entry #{report_ien} (#{adverse_reaction_field_name(related_field)})"

    internal = entry[:fields].dig(severity_field, :internal).to_s
    assert_equal expected_code, internal,
                 "SEVERITY on #120.85 entry #{report_ien} (#{adverse_reaction_field_name(severity_field)})"
  end

  def adverse_reaction_related_field!
    by_name = adverse_reaction_field_numbers.select do |num|
      adverse_reaction_field_name(num)&.match?(/RELATED REACTION|RELATED.*120\.8/i)
    end
    unless by_name.empty?
      flunk "ambiguous RELATED REACTION fields on #120.85: #{by_name.join(', ')}" if by_name.size > 1
      return by_name.first
    end

    name = adverse_reaction_field_name(".03")
    return ".03" if name&.match?(/RELATED REACTION/i)

    flunk "no RELATED REACTION field name in DDR VALIDATE on #120.85 on this build"
  end

  def adverse_reaction_severity_field!
    by_name = adverse_reaction_field_numbers.select do |num|
      adverse_reaction_field_name(num)&.match?(/SEVERITY|\bSEVER\b/i)
    end
    unless by_name.empty?
      flunk "ambiguous SEVERITY fields on #120.85: #{by_name.join(', ')}" if by_name.size > 1
      return by_name.first
    end

    flunk "no SEVERITY field name in DDR VALIDATE on #120.85 on this build"
  end

  ADVERSE_REACTION_FIELD_CANDIDATES = (
    %w[.01 .02 .03 .5 1.1 1.2 14.5] + (1..65).map(&:to_s)
  ).freeze

  def adverse_reaction_field_numbers
    ADVERSE_REACTION_FIELD_CANDIDATES.filter_map do |field|
      field if adverse_reaction_field_name(field)
    end
  end

  def adverse_reaction_field_name(field)
    reply = RpmsRpc::DdrFileman.validate_field(
      file: ADVERSE_REACTION_FILE, iens: "0,", field: field.to_s, value: "INVALIDTEST"
    )
    return nil if reply.nil?

    msg = reply[:errors].first.to_s
    return nil if msg.include?("multi-valued") || msg.include?("word-processing")
    return nil if msg.include?("does not contain a field")

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
      reaction_date: now,
      severity: SEVERITY_CODE
    }
  end

  def server_now_fm
    value = Array(client.call_rpc("ORWU DT", "NOW")).first.to_s
    RpmsRpc::FilemanDateParser.parse_datetime(value)&.then { |t| RpmsRpc::FilemanDateParser.format_datetime(t) } ||
      flunk("ORWU DT NOW answered #{value.inspect}")
  end
end
