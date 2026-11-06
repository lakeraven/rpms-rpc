# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/registration"
require "rpms_rpc/api/ddr_fileman"

# The reasons behind a patient's eligibility status (rpms-ux S-REG-07.3): the
# ELIGIBILITY MODIFIERS multiple of IHS PATIENT, DINUM'd to #9000030, filed
# with DDR FILER because AG's GUI has no window for it. Each write is read back
# through FileMan, and the spec removes what it adds.
class PatientEligibilityModifiersLiveTest < LiveSpec::Test
  writes!

  DFN = 990_008 # HOTEL,DREW, a synthetic seed patient
  REG = RpmsRpc::Registration

  def setup
    super
    assert REG.update(DFN, eligibility_status: "D")[:success]
    @choices = REG.eligibility_modifier_choices("D")
    refute_empty @choices, "the demo file has reasons for status D"
    clear
  end

  def teardown
    clear if client
    super
  end

  def clear
    REG.eligibility_modifiers(DFN).each { |row| REG.remove_eligibility_modifier(DFN, row[:ien]) }
  end

  def filed
    listed = RpmsRpc::ContextScope.scoped(RpmsRpc.client, REG::CONTEXT) do
      RpmsRpc::DdrFileman.lister(file: "9000001.03401", iens: ",#{DFN},", fields: "@;.01I", flags: "IP")
    end
    listed[:entries].map { |entry| [ entry[:ien].to_i, entry[:pieces][0].to_i ] }
  end

  def test_s_reg_07_3_each_reason_is_one_entry_pointing_at_its_modifier_and_can_be_removed
    first, second = @choices.first(2).map { |row| row[:ien] }

    assert REG.add_eligibility_modifier(DFN, first)[:success]
    assert REG.add_eligibility_modifier(DFN, second)[:success]

    assert_equal [ first, second ].sort.map { |ien| [ ien, ien ] }, filed.sort
    assert_equal @choices.first(2).map { |row| row[:name] }.sort, REG.eligibility_modifiers(DFN).map { |row| row[:name] }.sort

    assert REG.remove_eligibility_modifier(DFN, first)[:success]
    assert_equal [ [ second, second ] ], filed
    assert_equal :not_found, REG.remove_eligibility_modifier(DFN, first)[:error]
  end

  def test_s_reg_07_3_no_reason_twice_and_only_reasons_of_the_status
    reason = @choices.first[:ien]
    assert REG.add_eligibility_modifier(DFN, reason)[:success]

    assert_equal "is already recorded", REG.add_eligibility_modifier(DFN, reason)[:message]
    other = (REG.eligibility_modifier_choices("C").map { |row| row[:ien] } - @choices.map { |row| row[:ien] }).first
    assert_equal "is not a reason for this eligibility status", REG.add_eligibility_modifier(DFN, other)[:message]
    assert_equal [ [ reason, reason ] ], filed
  end
end
