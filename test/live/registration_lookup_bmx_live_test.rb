# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/patient"
require "securerandom"

# Registration's duplicate lookup runs over BMX (rpms-rpc#609, dev-lead call
# 2026-11-09). Over CIA an M error inside AGG LOOKUP PATIENTS answers the same
# bytes as a genuine no-match, so a CIA session cannot tell "nobody" from "the
# lookup broke"; over BMX the error rides the security packet and raises.
#
# On the wire, signed on over CIA with a BMX lookup client for the same
# persona: a no-match over BMX reads as no match and the registration files
# one patient; the repeat finds that patient; a lookup that faults inside FND
# fails closed over BMX and reads as zero candidates over CIA; and register
# over CIA with no lookup client scoped refuses and files nothing.
#
# Creates one synthetic patient: run on a disposable container and discard it.
# Needs BMX_PORT (the container's 9101). PROFILE,REG holds AGGRPC.
class RegistrationLookupBmxLiveTest < LiveSpec::Test
  writes!

  FAULT_PAIR = { "1BAD" => "X" }.freeze # not a valid M local: S @NAME=VALUE faults (AGGPTLKP.m:39)

  def test_a_no_match_over_bmx_registers_and_the_repeat_is_a_duplicate
    attrs = fresh_identity
    first = RpmsRpc::Registration.with_lookup_client(lookup_client) { RpmsRpc::Patient.register(attrs) }
    assert first && first[:success], "no candidate over BMX, so the registration files: #{first.inspect}"

    second = RpmsRpc::Registration.with_lookup_client(lookup_client) { RpmsRpc::Patient.register(attrs) }
    assert_equal :duplicate_identity, second[:error]
    assert_equal [ first[:dfn] ], second[:candidate_dfns]
    puts "\n#{persona}: registered DFN #{first[:dfn]} after a BMX no-match; the repeat found it"
  end

  def test_a_lookup_that_faults_fails_closed_over_bmx_and_reads_as_no_match_over_cia
    text = RpmsRpc::Agg.encode_parms(no_match_params.merge(FAULT_PAIR))

    assert_raises(RpmsRpc::Client::ConnectionError, "over BMX the fault is the security packet") do
      RpmsRpc.with_client(lookup_client) { aggrpc_lookup(lookup_client, text) }
    end
    assert_equal [], aggrpc_lookup(client, text), "over CIA the same fault answers zero candidates: why the lookup moved"
  end

  def test_register_over_cia_without_a_lookup_client_refuses_and_files_nothing
    attrs = fresh_identity
    result = RpmsRpc::Patient.register(attrs)
    assert_equal :identity_unverifiable, result[:error]

    found = RpmsRpc.with_client(lookup_client) { RpmsRpc::Agg.registration_candidates(params_for(attrs)) }
    assert_equal [], found, "nothing was filed"
  end

  private

  def aggrpc_lookup(session, text)
    RpmsRpc::Agg.send(:in_context, session) do
      RpmsRpc::Patient.lookup(text, all_divisions: true, include_inactive: true, require_response: true)
    end
  end

  def no_match_params = params_for(fresh_identity)

  def params_for(attrs)
    { "AGGPTLNM" => attrs[:name_last], "AGGPTFNM" => attrs[:name_first], "AGGPTMNM" => "", "AGGPTSFX" => "",
      "AGGPTDOB" => attrs[:dob].strftime("%m/%d/%Y") }
  end

  # A synthetic name and a DOB no patient has, checked over BMX.
  def fresh_identity
    suffix = SecureRandom.hex(6).tr("0-9", "G-P").upcase
    attrs = { name_last: "ZZBMXLOOKUP#{suffix}", name_first: "DEMO", dob: Date.new(1901, 2, 3), sex: "F", no_ssn_reason: "N" }
    366.times do
      found = RpmsRpc.with_client(lookup_client) { RpmsRpc::Agg.registration_candidates(params_for(attrs)) }
      return attrs if found.empty?

      attrs[:dob] += 1
    end
    flunk "no free synthetic DOB in 1901 for #{attrs[:name_last]}"
  end
end
