# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/api/agg"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/registration"
require_relative "../captured_replies"

# The preferred name (rpms-ux S-REG-12.1): #9000001 9001, read with DDR GETS
# and filed with DDR FILER inside AG's edit lock, as $$SETPREF^AUPNSOGI files
# it (openrpms#1059, rpms-rpc#549).
#
# Every reply is the pinned build's, captured as PROFILE,REG on seed patient
# HOTEL,DREW (test/fixtures/captured_replies/registration-preferred-name.yml),
# replayed through CiaClient; the AGG lock replies go through CiaClient's own
# GLOBAL ARRAY read. test/live/registration_preferred_name_live_test.rb proves
# the round trip and the search by the preferred name.
class RegistrationPreferredNameTest < Minitest::Test
  Reg = RpmsRpc::Registration
  SLUG = "registration-preferred-name"
  DFN = 990_008
  LOCK = "AGG LOCK PATIENT"
  UNLOCK = "AGG UNLOCK PATIENT"
  GETS = "DDR GETS ENTRY DATA"
  FILER = "DDR FILER"

  def teardown
    RpmsRpc.reset!
  end

  # A CiaClient answering each RPC with the named captures, in order.
  def replay(script = {})
    @client = CapturedReplies::ReplayCiaClient.new(script.transform_values { |names| Array(names).map { |n| CapturedReplies.raw(SLUG, n) } })
    RpmsRpc.configure { |cfg| cfg.client = @client }
    @client
  end

  # The lock, the read of what is stored, an optional filer reply, the unlock.
  def edit(stored, filer = nil)
    script = { LOCK => "lock", GETS => stored, UNLOCK => "unlock" }
    script[FILER] = filer if filer
    replay(script)
  end

  def sent(name) = CapturedReplies.file(SLUG).fetch("captures").find { |c| c["name"] == name }.fetch("inputs")
  def rpcs_sent = @client.rpcs_called.reject { |rpc| rpc == :create_context }
  def filer_calls = @client.calls.select { |c| c[:rpc] == FILER }

  def test_s_reg_12_1_reads_the_stored_preferred_name
    replay(GETS => "read_bobby")

    assert_equal "Bobby", Reg.preferred_name(DFN)
    assert_equal [ { rpc: GETS, params: sent("read_bobby") } ], @client.calls.reject { |c| c[:rpc] == :create_context }
  end

  def test_s_reg_12_1_reads_blank_as_none_on_file
    replay(GETS => "read_blank")

    assert_equal "", Reg.preferred_name(DFN)
  end

  # DDR GETS answers [ERROR] for an entry that does not exist.
  def test_s_reg_12_1_a_failed_read_raises_rather_than_reading_as_none
    replay(GETS => "read_no_such_patient")

    assert_raises(RpmsRpc::Client::RpcError) { Reg.preferred_name(999_999) }
  end

  def test_s_reg_12_1_files_9001_with_one_ddr_filer_edit_inside_the_ag_lock
    edit("read_blank", "file_bobby")

    assert_equal({ success: true, changed: true }, Reg.set_preferred_name(DFN, "  Bobby  "))

    assert_equal [ LOCK, GETS, FILER, UNLOCK ], rpcs_sent
    assert_equal sent("file_bobby"), filer_calls.first[:params]
  end

  def test_s_reg_12_1_a_blank_name_clears_the_field_with_an_at_sign
    edit("read_bobby", "file_clear")

    assert Reg.set_preferred_name(DFN, " ")[:success]
    assert_equal sent("file_clear"), filer_calls.first[:params]
  end

  def test_s_reg_12_1_an_unchanged_name_files_nothing
    edit("read_bobby")

    assert_equal({ success: true, changed: false }, Reg.set_preferred_name(DFN, "Bobby"))
    assert_empty filer_calls
    assert_equal UNLOCK, rpcs_sent.last
  end

  # DDR GETS answers [ERROR] for an entry that is not on file: no filing,
  # and the lock is released.
  def test_s_reg_12_1_a_read_that_finds_no_patient_files_nothing_and_unlocks
    edit("read_no_such_patient")

    assert_equal :not_found, Reg.set_preferred_name(DFN, "Bobby")[:error]
    assert_empty filer_calls
    assert_equal UNLOCK, rpcs_sent.last
  end

  # The build's answer when another user holds AG's lock on the patient.
  def test_s_reg_12_1_a_held_lock_sends_no_ddr_call
    replay(LOCK => "lock_held")

    assert_equal :lock_failed, Reg.set_preferred_name(DFN, "Bobby")[:error]
    refute(rpcs_sent.any? { |rpc| rpc.start_with?("DDR") })
  end

  # FileMan's refusal is the build's, for an EDIT of an entry that does not
  # exist: what matters here is that a [BEGIN_diERRORS] reply is a failure
  # that carries FileMan's own words, and the lock is still released.
  def test_s_reg_12_1_a_filer_refusal_is_filer_failed_with_filemans_reason
    edit("read_blank", "file_no_such_patient")

    result = Reg.set_preferred_name(DFN, "Bobby")

    assert_equal :filer_failed, result[:error]
    assert_includes result[:message], "The entry does not exist."
    assert_equal UNLOCK, rpcs_sent.last
  end

  def test_s_reg_12_1_refuses_what_the_input_transform_or_the_wire_would_refuse_without_an_rpc
    replay

    assert_equal :invalid, Reg.set_preferred_name(DFN, "x" * 31)[:error]
    assert_equal :invalid, Reg.set_preferred_name(DFN, "Bob^by")[:error]
    assert_equal :invalid, Reg.set_preferred_name(DFN, "@")[:error]
    assert_equal :invalid, Reg.set_preferred_name(0, "Bobby")[:error]
    assert_empty rpcs_sent
  end
end
