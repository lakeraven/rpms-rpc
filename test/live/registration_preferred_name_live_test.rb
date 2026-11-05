# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/registration"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/patient"

# The preferred name (rpms-ux S-REG-12.1): #9000001 9001, filed through DDR
# FILER inside AG's edit lock (rpms-ops#1059), read back through FileMan, and
# found by a patient search through the field's BPRF cross-reference. AGG
# LOOKUP PATIENTS uppercases what it is given, so only an uppercase preferred
# name is found by search; the gem files the case it is given, as SETPREF does.
class RegistrationPreferredNameLiveTest < LiveSpec::Test
  writes!

  DFN = 990_008 # HOTEL,DREW, a synthetic seed patient
  Reg = RpmsRpc::Registration

  def stored
    reply = RpmsRpc::DdrFileman.gets_entry(file: "9000001", iens: "#{DFN},", fields: "9001", flags: "I")
    refute_nil reply, "DDR GETS ENTRY DATA gave no reply"
    reply[:fields].dig("9001", :internal)
  end

  def test_s_reg_12_1_preferred_name_files_reads_back_and_is_found_by_search
    @before = Reg.preferred_name(DFN)

    assert_equal({ success: true, changed: true }, Reg.set_preferred_name(DFN, "DEE LIVE"))
    assert_equal "DEE LIVE", stored
    assert_equal "DEE LIVE", Reg.preferred_name(DFN)
    assert_includes RpmsRpc::Patient.lookup("HOTEL,DEE LIVE").map { |row| row[:dfn] }, DFN

    assert_equal({ success: true, changed: false }, Reg.set_preferred_name(DFN, "DEE LIVE"))

    assert Reg.set_preferred_name(DFN, "")[:success]
    assert_equal "", stored
    refute_includes RpmsRpc::Patient.lookup("HOTEL,DEE LIVE").map { |row| row[:dfn] }, DFN
  ensure
    assert Reg.set_preferred_name(DFN, @before.to_s)[:success] if client && @before
  end

  def test_s_reg_12_1_refuses_a_name_over_30_characters_and_files_nothing
    before = stored

    assert_equal :invalid, Reg.set_preferred_name(DFN, "X" * 31)[:error]
    assert_equal before, stored
  end
end
