# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/allergen"
require "rpms_rpc/api/allergy"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/fileman_date_parser"

# RpmsRpc::Allergen.search over ORWDAL32 ALLERGY MATCH (rpms-rpc#762): a match
# goes into Allergy.save unchanged, and #120.8 holds the agent and the pointer
# the search gave. It WRITES against a disposable local container only.
class AllergenSearchLiveTest < LiveSpec::Test
  writes!

  # An isolated synthetic patient no other live spec writes to.
  DFN = 990_036
  PATIENT_ALLERGY_FILE = "120.8"
  GMR_ALLERGY_FIELD = "1"

  # Texts with matches on the build, tried in order until one gives an agent
  # this patient does not have yet, so a reused volume still has one to file.
  ALLERGY_FILE_TEXTS = %w[STRAWB ABALO AVOCA BANAN CHOCOL PEANU SHELLF TOMAT].freeze
  GENERIC_DRUG_TEXTS = %w[AMOXICILLIN AMPICILLIN CEPHALEXIN DOXYCYCLINE ERYTHROMYCIN TETRACYCLINE].freeze

  def test_search_finds_allergens_and_drugs_and_no_match_is_empty
    strawberries = RpmsRpc::Allergen.search("STRAWB")
    refute_empty strawberries, "STRAWB should match GMR ALLERGIES on this build"
    assert(strawberries.all? { |m| m[:agent_pointer].match?(RpmsRpc::Allergy::AGENT_POINTER) }, strawberries.inspect)
    assert(strawberries.any? { |m| m[:synonym] }, "STRAWB should also match a synonym: #{strawberries.inspect}")

    drugs = RpmsRpc::Allergen.search("AMOXICILLIN")
    assert(drugs.any? { |m| m[:source] == "3" && m[:agent_pointer].end_with?(";PSNDF(50.6,") }, drugs.inspect)

    assert_equal [], RpmsRpc::Allergen.search("ZZZQX")
  end

  def test_an_allergy_file_match_saves_and_reads_back_with_its_pointer
    match = unused_match!(ALLERGY_FILE_TEXTS) { |m| m[:source] == "1" && m[:synonym].nil? }

    assert_saved_with_pointer!(match)
  end

  def test_a_generic_drug_match_saves_and_reads_back_with_its_pointer
    match = unused_match!(GENERIC_DRUG_TEXTS) { |m| m[:source] == "3" }

    assert_saved_with_pointer!(match)
  end

  private

  def unused_match!(texts)
    on_file = RpmsRpc::Allergy.for_patient(DFN).map { |row| row[:allergen].to_s.upcase }
    texts.each do |text|
      found = RpmsRpc::Allergen.search(text).find { |m| yield(m) && !on_file.include?(m[:agent].upcase) }
      return found if found
    end
    flunk "no match for #{texts.inspect} that DFN #{DFN} does not already have"
  end

  def assert_saved_with_pointer!(match)
    result = RpmsRpc::Allergy.save(DFN, {
      agent: match[:agent], agent_pointer: match[:agent_pointer], type: match[:type], nature: "A",
      originator: client.duz, originated_at: server_now_fm, observed_or_historical: "h"
    })
    assert result[:success], "Allergy.save with search match #{match.inspect}: #{result.inspect}"

    row = RpmsRpc::Allergy.for_patient(DFN).find { |r| r[:allergen].to_s.casecmp?(match[:agent]) }
    refute_nil row, "#{match[:agent]} should be on DFN #{DFN} after the save"

    entry = RpmsRpc::DdrFileman.gets_entry(
      file: PATIENT_ALLERGY_FILE, iens: "#{row[:ien]},", fields: GMR_ALLERGY_FIELD, flags: "IE"
    )
    flunk "DDR GETS on allergy #{row[:ien]} returned nothing: #{entry.inspect}" if entry.nil? || entry[:fields].empty?
    assert_equal match[:agent_pointer], entry[:fields].dig(GMR_ALLERGY_FIELD, :internal), "GMR ALLERGY (#120.8, 1) pointer"

    puts "\n#{persona}: #{match[:agent]} (#{match[:agent_pointer]}) found by search, filed as allergy #{row[:ien]} on DFN #{DFN}"
  end

  def server_now_fm
    value = Array(client.call_rpc("ORWU DT", "NOW")).first.to_s
    RpmsRpc::FilemanDateParser.parse_datetime(value)&.then { |t| RpmsRpc::FilemanDateParser.format_datetime(t) } ||
      flunk("ORWU DT NOW answered #{value.inspect}")
  end
end
