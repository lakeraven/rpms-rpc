# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/patient_profile"
require "rpms_rpc/api/agg"
require "rpms_rpc/api/ddr_fileman"

# A clerk answers the migrant, homeless and internet questions AG's edit check
# warns about (rpms-ux S-REG-31.2, 31.3), through AG's Other Patient window. The
# answers are dated multiples of #9000001 that AG cannot delete, so the spec
# removes them with DDR FILER, leaving the patient as it found them.
class PatientSocialStatusLiveTest < LiveSpec::Test
  writes!

  DFN = 990_008 # HOTEL,DREW, a synthetic seed patient
  SUBFILES = { "9000001.81" => 81, "9000001.84" => 84, "9000001.85" => 85 }.freeze
  EDIT_CHECK_WARNINGS = %w[37 39 40].freeze # internet, migrant, homeless

  def setup
    super
    clear_answers
  end

  def teardown
    clear_answers if client
    super
  end

  def warnings
    RpmsRpc::Agg.edit_check(dfn: DFN)[:checks].map { |check| check[:hide_error_num] }
  end

  def clear_answers
    SUBFILES.each_key do |file|
      listed = RpmsRpc::DdrFileman.lister(file: file, iens: ",#{DFN},", fields: "@;.01I", flags: "IP")
      listed[:entries].each do |entry|
        row = { file: file, field: ".01", iens: "#{entry[:ien]},#{DFN},", value: "@" }
        RpmsRpc::DdrFileman.filer(mode: "EDIT", rows: [ row ])
      end
    end
  end

  def test_s_reg_31_2_each_answer_is_on_file_and_ag_no_longer_warns
    assert_empty EDIT_CHECK_WARNINGS - warnings, "AG warns about all three on a patient with no answers"

    result = RpmsRpc::PatientProfile.record_social_status(DFN, migrant: "Y", migrant_type: "S", homeless: "N", internet: true)

    assert_equal({ success: true, dfn: DFN }, result)
    status = RpmsRpc::PatientProfile.social_status(DFN)
    assert_equal "Y", status[:migrant][:status]
    assert_equal "S", status[:migrant][:type]
    assert_equal "N", status[:homeless][:status]
    assert_nil status[:homeless][:type]
    assert_equal true, status[:internet][:access]
    refute_nil status[:internet][:date]
    assert_empty EDIT_CHECK_WARNINGS & warnings, "AG's edit check lists none of them now"
  end

  def test_only_what_is_given_is_recorded
    assert RpmsRpc::PatientProfile.record_social_status(DFN, internet: false)[:success]

    status = RpmsRpc::PatientProfile.social_status(DFN)
    assert_equal false, status[:internet][:access]
    assert_nil status[:migrant][:status], "an answer not given is not filed"
    assert_nil status[:homeless][:status]
  end

  def test_refusals_file_nothing
    assert_equal :invalid, RpmsRpc::PatientProfile.record_social_status(DFN, migrant: "Y")[:error]
    assert_equal :invalid, RpmsRpc::PatientProfile.record_social_status(DFN, migrant: "Y", migrant_type: "X")[:error]
    assert_equal :invalid, RpmsRpc::PatientProfile.record_social_status(DFN, homeless: "N", homeless_type: "S")[:error]
    assert_equal :no_fields, RpmsRpc::PatientProfile.record_social_status(DFN)[:error]
    assert_raises(ArgumentError) { RpmsRpc::PatientProfile.record_social_status(DFN, migrant: "yes") }

    status = RpmsRpc::PatientProfile.social_status(DFN)
    assert_nil status[:migrant][:status]
    assert_nil status[:homeless][:status]
  end
end
