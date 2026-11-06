# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/patient_profile"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/tribal"

# A patient with a second tribe (rpms-ux S-REG-07.2), through AG's Other Tribe
# window. Refusals are AG's own quantum check (S-REG-07.8) and the two AG's
# client makes before it saves (S-REG-07.9).
class PatientOtherTribesLiveTest < LiveSpec::Test
  writes!

  DFN = 990_008 # HOTEL,DREW, a synthetic seed patient
  TRIBE = 5     # a tribe the seed does not give this patient
  SECOND = 6
  SITE = 7819   # the demo facility

  def setup
    super
    clear_tribes
  end

  def teardown
    clear_tribes if client
    super
  end

  def clear_tribes
    RpmsRpc::PatientProfile.other_tribes(DFN).each { |row| RpmsRpc::PatientProfile.remove_other_tribe(DFN, row[:ien]) }
  end

  def filed(ien)
    reply = RpmsRpc::DdrFileman.gets_entry(file: "9000001.43", iens: "#{ien},#{DFN},", fields: ".01;.02", flags: "I")
    reply[:fields].transform_values { |value| value[:internal] }
  end

  def test_s_reg_07_2_a_second_tribe_and_its_quantum_are_on_file_and_can_be_removed
    result = RpmsRpc::PatientProfile.add_other_tribe(DFN, tribe: TRIBE, quantum: "1/8")

    assert result[:success], result.inspect
    row = RpmsRpc::PatientProfile.other_tribes(DFN).first
    assert_equal TRIBE, row[:tribe_ien]
    refute_empty row[:tribe]
    assert_equal({ ".01" => TRIBE.to_s, ".02" => "1/8" }, filed(row[:ien]))

    assert RpmsRpc::PatientProfile.remove_other_tribe(DFN, row[:ien])[:success]
    assert_empty RpmsRpc::PatientProfile.other_tribes(DFN)
    assert_equal :not_found, RpmsRpc::PatientProfile.remove_other_tribe(DFN, row[:ien])[:error]
  end

  def test_s_reg_07_9_the_tribe_of_membership_or_a_tribe_listed_twice_is_refused
    membership = RpmsRpc::Tribal.enrollment(DFN)[:tribe_ien]
    assert_equal :invalid, RpmsRpc::PatientProfile.add_other_tribe(DFN, tribe: membership, quantum: "1/8")[:error]

    assert RpmsRpc::PatientProfile.add_other_tribe(DFN, tribe: TRIBE, quantum: "1/8")[:success]
    refused = RpmsRpc::PatientProfile.add_other_tribe(DFN, tribe: TRIBE, quantum: "1/8")

    assert_equal "is already listed", refused[:message]
    assert_equal 1, RpmsRpc::PatientProfile.other_tribes(DFN).size
  end

  # AG checks quantums only where the site records them (#9009061 field 1),
  # and the demo site does not.
  def records_tribal_quantums(value)
    in_vuecentric do
      RpmsRpc::DdrFileman.filer(mode: "EDIT", rows: [ { file: "9009061", field: "1", iens: "#{SITE},", value: value } ])
    end
  end

  def in_vuecentric(&block) = RpmsRpc::ContextScope.scoped(RpmsRpc.client, RpmsRpc::Registration::CONTEXT, &block)

  def test_s_reg_07_8_quantums_over_the_indian_blood_quantum_are_refused
    assert records_tribal_quantums("Y")[:success]
    assert RpmsRpc::Registration.update(DFN, blood_quantum: "1/4", tribe_quantum: "1/8")[:success]
    assert RpmsRpc::PatientProfile.add_other_tribe(DFN, tribe: TRIBE, quantum: "1/16")[:success]

    refused = RpmsRpc::PatientProfile.add_other_tribe(DFN, tribe: SECOND, quantum: "1/8")

    assert_equal :invalid, refused[:error]
    assert_match(/greater than the Indian Blood Quantum/, refused[:message])
    assert_equal 1, RpmsRpc::PatientProfile.other_tribes(DFN).size
  ensure
    records_tribal_quantums("N") if client
  end
end
