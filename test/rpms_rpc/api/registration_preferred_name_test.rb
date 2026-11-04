# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/agg"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/registration"

# Hermetic tests for the preferred name (rpms-ux S-REG-12.1): #9000001 9001,
# read with DDR GETS and filed with DDR FILER inside AG's edit lock, as
# $$SETPREF^AUPNSOGI files it (rpms-ops#1059, rpms-rpc#549).
class RegistrationPreferredNameTest < Minitest::Test
  Reg = RpmsRpc::Registration
  Ddr = RpmsRpc::DdrFileman
  LOCK_OK = "I00010RESULT^T00080MESSAGE\x1e1^\x1e\x1f"
  LOCK_HELD = "I00010RESULT^T00080MESSAGE\x1e0^Held by DEMO,USER.\x1e\x1f"
  DFN = 990_042

  def setup
    @mock = RpmsRpc.mock!
  end

  def teardown
    RpmsRpc.reset!
  end

  def rpcs_sent = @mock.received_calls.map { |c| c[:rpc] }
  def filer_calls = @mock.received_calls.select { |c| c[:rpc] == "DDR FILER" }

  def seed_lock(reply = LOCK_OK)
    @mock.seed(:agg_lock_patient, DFN.to_s, reply)
    @mock.seed(:agg_unlock_patient, DFN.to_s, LOCK_OK)
  end

  def seed_stored(text)
    key = Ddr.gets_entry_param(file: "9000001", iens: "#{DFN},", fields: "9001", flags: "I").to_s
    @mock.seed(:ddr_gets_entry_data, key, text)
  end

  def seed_stored_name(name)
    seed_stored("[Data]\n9000001^#{DFN},^9001^#{name}^#{name}")
  end

  def test_s_reg_12_1_reads_the_stored_preferred_name
    seed_stored_name("Bobby")

    assert_equal "Bobby", Reg.preferred_name(DFN)
  end

  def test_s_reg_12_1_reads_blank_as_none_on_file
    seed_stored_name("")

    assert_equal "", Reg.preferred_name(DFN)
  end

  def test_s_reg_12_1_a_failed_read_raises_rather_than_reading_as_none
    seed_stored("[Data]")

    assert_raises(RpmsRpc::Client::RpcError) { Reg.preferred_name(DFN) }
  end

  def test_s_reg_12_1_files_9001_with_one_ddr_filer_edit_inside_the_ag_lock
    seed_lock
    seed_stored_name("")
    @mock.seed(:ddr_filer, "EDIT", "[Data]")

    assert_equal({ success: true, changed: true }, Reg.set_preferred_name(DFN, "  Bobby  "))

    assert_equal [ "AGG LOCK PATIENT", "DDR GETS ENTRY DATA", "DDR FILER", "AGG UNLOCK PATIENT" ],
                 rpcs_sent.reject { |rpc| rpc.start_with?("XWB", "CIA") }
    assert_equal({ 1 => "9000001^9001^#{DFN},^Bobby" }, filer_calls.first[:params][1])
  end

  def test_s_reg_12_1_a_blank_name_clears_the_field_with_an_at_sign
    seed_lock
    seed_stored_name("Bobby")
    @mock.seed(:ddr_filer, "EDIT", "[Data]")

    assert Reg.set_preferred_name(DFN, " ")[:success]
    assert_equal({ 1 => "9000001^9001^#{DFN},^@" }, filer_calls.first[:params][1])
  end

  def test_s_reg_12_1_an_unchanged_name_files_nothing
    seed_lock
    seed_stored_name("Bobby")

    assert_equal({ success: true, changed: false }, Reg.set_preferred_name(DFN, "Bobby"))
    assert_empty filer_calls
  end

  def test_s_reg_12_1_a_failed_read_files_nothing_and_unlocks
    seed_lock
    seed_stored("[Data]")

    assert_equal :lookup_failed, Reg.set_preferred_name(DFN, "Bobby")[:error]
    assert_empty filer_calls
    assert_equal "AGG UNLOCK PATIENT", rpcs_sent.last
  end

  def test_s_reg_12_1_a_held_lock_sends_no_ddr_call
    seed_lock(LOCK_HELD)

    assert_equal :lock_failed, Reg.set_preferred_name(DFN, "Bobby")[:error]
    refute(rpcs_sent.any? { |rpc| rpc.start_with?("DDR") })
  end

  def test_s_reg_12_1_a_filer_refusal_is_filer_failed_with_filemans_reason
    seed_lock
    seed_stored_name("")
    @mock.seed(:ddr_filer, "EDIT", "[Data]\n[BEGIN_diERRORS]\n701^1^9001^9000001\nThe value is not valid.\n[END_diERRORS]")

    result = Reg.set_preferred_name(DFN, "Bobby")

    assert_equal :filer_failed, result[:error]
    assert_includes result[:message], "not valid"
  end

  def test_s_reg_12_1_refuses_what_the_input_transform_or_the_wire_would_refuse_without_an_rpc
    assert_equal :invalid, Reg.set_preferred_name(DFN, "x" * 31)[:error]
    assert_equal :invalid, Reg.set_preferred_name(DFN, "Bob^by")[:error]
    assert_equal :invalid, Reg.set_preferred_name(DFN, "@")[:error]
    assert_equal :invalid, Reg.set_preferred_name(0, "Bobby")[:error]
    assert_empty rpcs_sent
  end
end
