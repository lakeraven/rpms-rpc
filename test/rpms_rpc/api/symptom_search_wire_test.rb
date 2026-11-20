# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mappings"
require "rpms_rpc/api/symptom"
require_relative "../captured_replies"

# ORWDAL32 SYMPTOMS as built (OR*3.0*233) sets Y(I)=IEN_U_FROM
# (ORWDAL32.m:118), and indexes each synonym as SYN_$C(9)_"<"_NAME_">"_U_NAME
# (ORWDAL32.m:109-111). A synonym row's third piece is the preferred symptom
# name, which the mapping read as :snomed_code (#221). The page is the one a
# fresh container of the pinned build sent after RASH
# (test/fixtures/captured_replies/symptom.yml), replayed through CiaClient.
class SymptomSearchWireTest < Minitest::Test
  def teardown
    RpmsRpc.reset!
  end

  def test_plain_and_synonym_rows
    RpmsRpc.reset!
    reply = CapturedReplies.raw("symptom", "from_rash")
    RpmsRpc.configure { |cfg| cfg.client = CapturedReplies::ReplayCiaClient.new("ORWDAL32 SYMPTOMS" => [ reply ]) }

    rows = RpmsRpc::Symptom.search("RASH")

    assert_equal({ ien: 378, name: "RECTAL HEMORRHAGE", preferred_name: nil }, rows.first)
    # The routine joins the synonym and its <NAME> with $C(9); CiaClient reads
    # every reply as printable text, so the host sees a space there.
    assert_includes rows, { ien: 78, name: "RED SKIN <ERYTHEMA>", preferred_name: "ERYTHEMA" }
    refute rows.any? { |r| r.key?(:snomed_code) }
  end
end
