# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/eligibility"

# Eligibility reads the immunization package's VFC eligibility, through the
# RPCs VueCentric's immunization component uses (both in CIAV VUECENTRIC,
# which the spec binds; reads only):
#
#   codes            BGOVIMM2 GETELIG: the active rows of BI TABLE ELIGIBILITY
#                    CODES (#9002084.83), IEN^code^label^local text
#                    (GETELIG^BGOVIMM2, BGOVIMM2.m:207-216)
#   for_patient(dfn) BGOVIMM GETVFC: IHS-site?^age^default (GETVFC^BGOVIMM2,
#                    BGOVIMM2.m:157-172). The default is a LABEL, "Am
#                    Indian/AK Native" when the patient's beneficiary type is
#                    1, else that type's IEN (0 when unset); the method
#                    resolves a label to its GETELIG row and nothing else.
#
# The demo patients are DFN 3, 990001 and 990027.
class EligibilityLiveTest < LiveSpec::Test
  CONTEXT = "CIAV VUECENTRIC"
  DEMO_DFNS = %w[3 990001 990027].freeze

  def test_codes_are_the_servers_active_eligibility_codes
    codes = client.with_context(CONTEXT) { RpmsRpc::Eligibility.codes }
    refute_empty codes, "BGOVIMM2 GETELIG listed no eligibility codes"
    codes.each do |row|
      assert_equal %i[code label], row.keys, "row #{row.inspect}"
      refute_empty row[:code].to_s, "row #{row.inspect} has no code"
      refute_empty row[:label].to_s, "row #{row.inspect} has no label"
    end
    assert_equal codes.map { |r| r[:code] }.uniq.size, codes.size, "a code is listed twice"
    %w[V01 V02 V03 V04 V05].each { |c| assert_includes codes.map { |r| r[:code] }, c }
    puts "\n#{persona}: #{codes.map { |r| "#{r[:code]} #{r[:label]}" }.join(' | ')}"
  end

  def test_for_patient_resolves_the_servers_default_to_a_code
    codes = client.with_context(CONTEXT) { RpmsRpc::Eligibility.codes }
    resolved = DEMO_DFNS.to_h do |dfn|
      got = client.with_context(CONTEXT) { RpmsRpc::Eligibility.for_patient(dfn) }
      raw = client.with_context(CONTEXT) { client.call_rpc("BGOVIMM GETVFC", dfn) }
      default = Array(raw).first.to_s.split("^", -1)[2].to_s
      expected = codes.find { |r| r[:label] == default } || RpmsRpc::Eligibility::NIL_ELIGIBILITY
      assert_equal expected, got, "DFN #{dfn}: GETVFC answered #{raw.inspect}"
      [ dfn, got ]
    end

    assert(resolved.values.any? { |r| r[:code] },
           "no demo patient resolved to an eligibility code: the build needs one with beneficiary type 1 " \
           "(#9000001 field 1111) at an IHS site")
    puts "\n#{persona}: #{resolved.map { |d, r| "#{d}=#{r[:code].inspect}" }.join(' ')}"
  end

  def test_an_invalid_dfn_is_nil_eligibility
    [ nil, "", "0", "-3", "abc" ].each do |bad|
      assert_equal RpmsRpc::Eligibility::NIL_ELIGIBILITY, RpmsRpc::Eligibility.for_patient(bad), bad.inspect
    end
  end
end
