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

  # rpms-rpc#610: a derived HRN (HRN := DFN) is filed after the create, past
  # AG's input transform, so HRN^AGGWVAL's already-assigned check (AGGWVAL.m:101-110)
  # never ran on it. A legacy number at this facility equal to the next DFN
  # then went onto a second patient. The derive path now asks AG's check first.
  # The number is set up the way a legacy chart number arrives: given, on the
  # patient registered just before, equal to the DFN the next patient gets.
  def test_a_derived_hrn_that_another_patient_holds_here_is_not_filed
    probe = RpmsRpc::Patient.register(synthetic(hrn_source: :derive))
    assert probe && probe[:success], "registration failed: #{probe.inspect}"
    legacy = (probe[:dfn].to_i + 2).to_s

    holder_attrs = synthetic(hrn_source: :given, hrn: legacy)
    holder = RpmsRpc::Patient.register(holder_attrs)
    assert holder && holder[:success], "registration failed: #{holder.inspect}"
    assert_equal probe[:dfn].to_i + 1, holder[:dfn].to_i,
                 "this spec needs DFNs handed out in order on a quiet container; got #{holder[:dfn]} after #{probe[:dfn]}"

    attrs = synthetic(hrn_source: :derive)
    result = RpmsRpc::Patient.register(attrs)
    assert_equal legacy, result[:dfn].to_s, "the derived patient's DFN is the legacy number: #{result.inspect}"
    refute result[:success], "a derived HRN another patient holds here must not be filed: #{result.inspect}"
    assert_equal :hrn_already_assigned, result[:error]
    assert_empty filed_hrns(attrs, result[:dfn]).reject(&:empty?), "no HRN is filed on the new chart"
    assert_includes filed_hrns(holder_attrs, holder[:dfn]).join(" "), legacy, "the holder keeps its number"
  end
end
