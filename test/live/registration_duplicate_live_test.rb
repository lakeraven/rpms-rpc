# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/patient"
require "securerandom"

# Creates one synthetic patient on a disposable container. There is no
# supported patient-delete RPC; discard the container after running this spec.
class RegistrationDuplicateLiveTest < LiveSpec::Test
  writes!

  def test_second_registration_refuses_without_creating_another_chart
    # Alphabetic suffix keeps the synthetic FileMan name valid and unique.
    suffix = SecureRandom.hex(6).tr("0-9", "G-P").upcase
    attrs = { name_last: "ZZREGSAFETY#{suffix}", name_first: "DEMO",
              dob: Date.new(1901, 2, 3), sex: "F" }
    # DOB searches are intentionally broad. Find an unused synthetic DOB
    # before the first registration so this spec never overrides candidates.
    params = { "AGGPTLNM" => attrs[:name_last], "AGGPTFNM" => attrs[:name_first] }
    366.times do
      params["AGGPTDOB"] = attrs[:dob].strftime("%m/%d/%Y")
      break if RpmsRpc::Agg.registration_candidates(params).empty?
      attrs[:dob] += 1
    end

    first = RpmsRpc::Patient.register(attrs)
    assert first && first[:success], "initial synthetic registration failed: #{first&.dig(:error)}"
    assert_operator first[:dfn], :>, 0

    # A fresh session also proves this is persisted identity, not Ruby state.
    @client.disconnect
    @client = sign_on
    second = RpmsRpc::Patient.register(attrs)
    assert_equal({ success: false, error: :duplicate_identity, candidate_dfns: [ first[:dfn] ],
                   message: "matching patient candidates require explicit override" }, second)

    params["AGGPTDOB"] = attrs[:dob].strftime("%m/%d/%Y")
    found = RpmsRpc::Agg.registration_candidates(params)
    assert_equal [ first[:dfn] ], found.map { |row| row[:dfn] }.uniq,
                 "the second registration must not add another patient"
  ensure
    RpmsRpc::Registration.hrn_mode = RpmsRpc::Registration::HRN_MODE_DERIVE
  end
end
