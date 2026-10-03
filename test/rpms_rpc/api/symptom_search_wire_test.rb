# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mappings"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/symptom"

# ORWDAL32 SYMPTOMS as built (OR*3.0*233) sets Y(I)=IEN_U_FROM
# (ORWDAL32.m:118), and indexes each synonym as SYN_$C(9)_"<"_NAME_">"_U_NAME
# (ORWDAL32.m:109-111). A synonym row's third piece is the preferred symptom
# name, which the mapping read as :snomed_code (#221). Rows below are the
# shape a live read of a built image answered.
class SymptomSearchWireTest < Minitest::Test
  class RawResponseClient
    def initialize(response) = @response = response
    def call_rpc(*) = @response
  end

  def teardown
    RpmsRpc.reset!
  end

  def test_plain_and_synonym_rows
    RpmsRpc.reset!
    RpmsRpc.configure do |cfg|
      cfg.client = RawResponseClient.new([ "133^RASH", "78^RED SKIN\t<ERYTHEMA>^ERYTHEMA" ])
    end

    rows = RpmsRpc::Symptom.search("RAS")

    assert_equal({ ien: 133, name: "RASH", preferred_name: nil }, rows.first)
    assert_equal({ ien: 78, name: "RED SKIN\t<ERYTHEMA>", preferred_name: "ERYTHEMA" }, rows.last)
    refute rows.any? { |r| r.key?(:snomed_code) }
  end
end
