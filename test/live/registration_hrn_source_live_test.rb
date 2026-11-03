# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/patient"
require "securerandom"

# Where a new patient's health record number comes from (rpms-ux S-REG-05,
# the mini-registration from scheduling): a temporary T-number AG hands out
# (AGG GET TEMP PAT HRN), or a number the clerk was given, which AG's own HRN
# check refuses when another patient holds it here. Creates synthetic
# patients on a disposable container; there is no supported patient-delete
# RPC, so discard the container afterwards.
class RegistrationHrnSourceLiveTest < LiveSpec::Test
  writes!

  def synthetic(**extra)
    suffix = SecureRandom.hex(5).tr("0-9", "G-P").upcase
    { name_last: "ZZHRN#{suffix}", name_first: "DEMO", dob: Date.new(1903, 1 + rand(12), 1 + rand(28)),
      sex: "F", no_ssn_reason: "N" }.merge(extra)
  end

  # The facility's chart numbers, as RPMS lists them on the patient: the
  # HEALTH RECORD NO. multiple (#9000001.41), read back through the lookup
  # the front desk uses.
  def filed_hrns(attrs, dfn)
    rows = RpmsRpc::Agg.registration_candidates("AGGPTLNM" => attrs[:name_last], "AGGPTFNM" => attrs[:name_first],
                                                "AGGPTDOB" => attrs[:dob].strftime("%m/%d/%Y"))
    rows.select { |row| row[:dfn] == dfn }.map { |row| row[:hrn].to_s }
  end

  def test_s_reg_05_1_a_temporary_number_is_filed_on_the_new_patient
    attrs = synthetic
    result = RpmsRpc::Patient.register(attrs.merge(hrn_source: :temporary))

    assert result && result[:success], "registration failed: #{result.inspect}"
    assert_match(/\AT\d{5}\z/, result[:hrn])
    assert_includes filed_hrns(attrs, result[:dfn]).join(" "), result[:hrn]

    following = RpmsRpc::Patient.register(synthetic(hrn_source: :temporary))
    assert following && following[:success], "the next registration failed: #{following.inspect}"
    refute_equal result[:hrn], following[:hrn], "each new patient gets its own temporary number"
  end

  def test_s_reg_05_2_and_05_5_a_given_number_is_filed_once_and_refused_for_a_second_patient
    number = format("%06d", 900_000 + rand(99_999))
    first_attrs = synthetic(hrn_source: :given, hrn: number)
    first = RpmsRpc::Patient.register(first_attrs)
    assert first && first[:success], "registration failed: #{first.inspect}"
    assert_equal number, first[:hrn]
    assert_includes filed_hrns(first_attrs, first[:dfn]).join(" "), number

    second_attrs = synthetic(hrn_source: :given, hrn: number)
    second = RpmsRpc::Patient.register(second_attrs)
    assert_equal :agg_invalid, second[:error]
    assert_equal "AGGPTHRN", second[:field]
    assert_match(/\AHRN #{number} is already assigned to patient /, second[:message])
    assert_empty RpmsRpc::Agg.registration_candidates("AGGPTLNM" => second_attrs[:name_last], "AGGPTFNM" => "DEMO",
                                                      "AGGPTDOB" => second_attrs[:dob].strftime("%m/%d/%Y")),
                 "the refused registration must file nothing"
  end
end
