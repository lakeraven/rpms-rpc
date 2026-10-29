# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/patient"
require "securerandom"

# AG's own field checks (AGG WINDOW DATA VALIDATION) run before AGG ADD NEW
# PATIENT, as AG's client runs them (rpms-ux S-REG-02.6, S-REG-02.8). ADD alone
# files a duplicate SSN. Creates synthetic patients on a disposable container;
# there is no supported patient-delete RPC, so discard the container afterwards.
class RegistrationWindowValidationLiveTest < LiveSpec::Test
  writes!

  def synthetic(**extra)
    suffix = SecureRandom.hex(5).tr("0-9", "G-P").upcase
    { name_last: "ZZVALID#{suffix}", name_first: "DEMO", dob: Date.new(1902, 1 + rand(12), 1 + rand(28)), sex: "F" }.merge(extra)
  end

  def fresh_ssn = "6660#{format('%05d', rand(100_000))}"

  def candidates(attrs)
    RpmsRpc::Agg.registration_candidates("AGGPTLNM" => attrs[:name_last], "AGGPTFNM" => attrs[:name_first],
                                         "AGGPTDOB" => attrs[:dob].strftime("%m/%d/%Y"))
  end

  def test_s_reg_02_8_an_ssn_already_on_another_patient_is_refused_and_nothing_is_filed
    ssn = fresh_ssn
    first = RpmsRpc::Patient.register(synthetic(ssn: ssn))
    assert first && first[:success], "the first registration failed: #{first.inspect}"

    second_attrs = synthetic(ssn: ssn)
    second = RpmsRpc::Patient.register(second_attrs)
    assert_equal({ success: false, error: :agg_invalid, field: "AGGPTSSN", message: "SSN already used by another patient." }, second)
    assert_empty candidates(second_attrs), "the refused registration must file nothing"
  end

  def test_an_ssn_and_a_reason_for_none_together_are_refused
    result = RpmsRpc::Patient.register(synthetic(ssn: fresh_ssn, no_ssn_reason: "R"))
    assert_equal :agg_invalid, result[:error]
    assert_match(/cannot enter both/, result[:message])
  end

  def test_no_ssn_with_a_reason_registers
    attrs = synthetic(no_ssn_reason: "R")
    result = RpmsRpc::Patient.register(attrs)
    assert result && result[:success], "registration with a reason for no SSN failed: #{result.inspect}"
    assert_equal [ result[:dfn] ], candidates(attrs).map { |row| row[:dfn] }.uniq
  end

  # S-REG-02.6. On this build AG's check of a missing reason errors in
  # ISREQ^AGGUL2 and leaves the broker job hanging on its next AG call
  # (rpms-ops#1040), so the gem does not send it and refuses. A registration
  # after it must still go through on the same session.
  def test_s_reg_02_6_no_ssn_and_no_reason_is_not_filed_unchecked
    attrs = synthetic
    result = RpmsRpc::Patient.register(attrs)
    assert_equal({ success: false, error: :ssn_or_reason_required, field: "AGGNOSSN",
                   message: "Enter a SSN or a Reason for No SSN" }, result)
    assert_empty candidates(attrs)

    after = RpmsRpc::Patient.register(synthetic(no_ssn_reason: "N"))
    assert after && after[:success], "the session must still register afterwards: #{after.inspect}"
  end
end
