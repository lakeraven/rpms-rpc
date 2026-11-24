# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/allergen"
require_relative "../captured_replies"

# Allergen.search reads the ORWDAL32 ALLERGY MATCH replies a container of
# the pinned build sent (test/fixtures/captured_replies/allergen.yml),
# replayed through CiaClient.
class AllergenTest < Minitest::Test
  SLUG = "allergen"
  RPC = "ORWDAL32 ALLERGY MATCH"

  def teardown
    RpmsRpc.reset!
  end

  def replay(script)
    client = CapturedReplies::ReplayCiaClient.new(script)
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def search(name, text)
    replay(RPC => [ CapturedReplies.raw(SLUG, name) ])
    RpmsRpc::Allergen.search(text)
  end

  def test_an_allergen_by_name_gives_the_agent_and_pointer_save_takes
    matches = search("strawb", "STRAWB")

    assert_equal(
      { agent: "STRAWBERRIES", agent_pointer: "6;GMRD(120.82,", synonym: nil, type: "DF",
        source: "1", source_name: "VA Allergies File" },
      matches.first
    )
    matches.each { |m| assert_match RpmsRpc::Allergy::AGENT_POINTER, m[:agent_pointer] }
  end

  def test_a_synonym_match_files_the_allergen_and_names_the_synonym
    synonym = search("strawb", "STRAWB").last

    assert_equal "STRAWBERRIES", synonym[:agent]
    assert_equal "STRAWBERRY", synonym[:synonym]
    assert_equal "6;GMRD(120.82,", synonym[:agent_pointer], "the synonym cross-reference is not part of the pointer"
  end

  def test_drug_file_matches_point_into_their_own_files
    pointers = {
      "amoxicillin" => [ "AMOXICILLIN", "95;PSNDF(50.6," ],
      "latex" => [ "LATEX", "3912;PS(50.416," ],
      "penicillins" => [ "PENICILLINS", "11;PS(50.605," ]
    }
    pointers.each do |name, (text, pointer)|
      first = search(name, text).first
      assert_equal pointer, first[:agent_pointer], name
      assert_equal "D", first[:type], name
    end
  end

  def test_a_trade_name_keeps_its_trade_name_and_pointer
    trade = search("aspirin_comma", "ASPIRIN,").find { |m| m[:source] == "4" }

    assert_equal "ASPIRIN,ENTERIC COATED", trade[:agent]
    assert_equal "964;PSNDF(50.67,", trade[:agent_pointer]
    assert_equal "National Drug file - Trade Name", trade[:source_name]
  end

  def test_no_match_is_empty_and_headers_are_never_matches
    assert_equal [], search("no_match", "ZZZQX")
    assert(search("aspirin_comma", "ASPIRIN,").none? { |m| m[:agent].end_with?("File") })
  end

  def test_sends_the_text_as_typed
    client = replay(RPC => [ CapturedReplies.raw(SLUG, "latex") ])
    RpmsRpc::Allergen.search("LATEX")

    assert_equal [ { rpc: RPC, params: [ "LATEX" ] } ], client.calls
  end

  def test_blank_text_is_empty_without_a_call
    client = replay({})

    assert_equal [], RpmsRpc::Allergen.search(nil)
    assert_equal [], RpmsRpc::Allergen.search("  ")
    assert_empty client.calls
  end
end
