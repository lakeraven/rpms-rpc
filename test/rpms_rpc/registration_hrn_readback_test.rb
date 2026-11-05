# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/registration"

# Issue #562 / #224: registration must fail closed when AG reports an HRN write
# but #9000001.41 read-back (DDR LISTER) does not confirm it.
class RegistrationHrnReadbackTest < Minitest::Test
  Reg = RpmsRpc::Registration
  Agg = RpmsRpc::Agg
  Ddr = RpmsRpc::DdrFileman

  ATTRS = {
    name: "DEMOPATIENT,UNA",
    dob: Date.new(1990, 1, 2),
    sex: "F",
    ssn: "900010001"
  }.freeze

  HEADER = "I00010DFN^T00030PATIENT_NAME^T00030HRN^T00009SSN^D00030DOB^D00030DOD^T00003SENS_FLAG^T01024ALIAS^T00001INACTIVE"

  def setup
    @mock = RpmsRpc.mock!
    Reg.hrn_mode = Reg::HRN_MODE_DERIVE
    query = "AGGPTLNM=DEMOPATIENT\x1cAGGPTFNM=UNA\x1cAGGPTMNM=\x1cAGGPTSFX=\x1cAGGPTDOB=01/02/1990"
    @mock.seed_raw_lines(:patient_lookup_agg, query, [ HEADER ])
    [ Agg::NEW_PATIENT_WINDOW, "Personal Detail", "Address", "Aliases" ].each do |window|
      seed_validation("1^^^^^\x1e", window: window)
    end
  end

  def teardown
    Reg.hrn_mode = Reg::HRN_MODE_DERIVE
    RpmsRpc.reset!
  end

  def seed_validation(row, window: Agg::NEW_PATIENT_WINDOW)
    header = "5\x00I00010RESULT^T00100MSG^T00001HANDLER^I00010IEN^T00008CODE^T00100REVALIDATE\x1e"
    @mock.seed(:agg_window_validation, window, header + row.to_s)
  end

  def seed_agg_add(dfn: "9", result: "1", message: "")
    reply = "I00010RESULT^T00080MESSAGE^I00010DFN\x1e#{result}^#{message}^#{dfn}\x1e\x1f"
    @mock.seed(:agg_add_patient, Agg::NEW_PATIENT_WINDOW, reply)
  end

  def seed_agg_update(result: "1", error: "")
    reply = "I00010RESULT^T01024ERROR^T01024OTHER_PARMS\x1e#{result}^#{error}^\x1e\x1f"
    @mock.seed(:agg_update_patient, Agg::DEFAULT_WINDOW, reply)
  end

  def seed_temp_hrn(number)
    @mock.seed(:agg_get_temp_pat_hrn, "9", "T00010AGGPTHRN\x1e#{number}\x1e\x1f")
  end

  def seed_hrn_41_readback(dfn, hrn_on_file)
    key = Ddr.lister_param(file: "9000001.41", iens: ",#{dfn},", fields: "@;.02", flags: "IP").to_s
    body =
      case hrn_on_file
      when :empty then "[Data]"
      when :error then "[Data]\n[Errors]"
      when :no_reply then return
      else "[Data]\n1^#{hrn_on_file}"
      end
    @mock.seed(:ddr_lister, key, body)
  end

  def hrn_lister_calls
    @mock.received_calls.select do |c|
      c[:rpc] == "DDR LISTER" && c[:params]["FILE"] == "9000001.41"
    end
  end

  def assert_hrn_readback_lister_fields
    refute_empty hrn_lister_calls, "expected a #9000001.41 DDR LISTER read-back"
    hrn_lister_calls.each do |call|
      assert_equal "@;.02", call[:params]["FIELDS"],
                   "read-back must suppress .01 so piece 0 is field .02 under every DDR version"
    end
  end

  def with_hrn_41_lister_raise(error_class)
    original = @mock.method(:call_rpc)
    @mock.define_singleton_method(:call_rpc) do |rpc, *params|
      param = params.first
      if rpc == "DDR LISTER" && param.is_a?(Hash) && param["FILE"] == "9000001.41"
        raise error_class, "synthetic #9000001.41 read-back failure"
      end

      original.call(rpc, *params)
    end
    yield
  end

  def refute_message_leaks_phi(message)
    text = message.to_s
    refute_match(/900010001|DEMOPATIENT|01\/02\/1990|1990-01-02|UNA|T00007|12345|^9$/, text)
  end

  def test_derive_hrn_success_requires_matching_9000001_41_readback
    seed_agg_add(dfn: "9")
    seed_agg_update
    seed_hrn_41_readback(9, "9")

    result = Reg.register(ATTRS)

    assert result[:success], "expected success only after #9000001.41 confirms HRN 9"
    assert_equal 1, hrn_lister_calls.length, "must read #9000001.41 before reporting success"
    assert_hrn_readback_lister_fields
  end

  def test_derive_hrn_empty_multiple_is_hrn_file_failed
    seed_agg_add(dfn: "9")
    seed_agg_update
    seed_hrn_41_readback(9, :empty)

    result = Reg.register(ATTRS)

    assert_equal :hrn_file_failed, result[:error]
    assert_equal 9, result[:dfn]
    refute result[:success]
    refute_message_leaks_phi(result[:message])
    assert_hrn_readback_lister_fields
  end

  def test_derive_hrn_mismatch_on_file_is_hrn_file_failed
    seed_agg_add(dfn: "9")
    seed_agg_update
    seed_hrn_41_readback(9, "99999")

    result = Reg.register(ATTRS)

    assert_equal :hrn_file_failed, result[:error]
    assert_equal 9, result[:dfn]
    refute_message_leaks_phi(result[:message])
  end

  def test_derive_hrn_unverified_when_lister_returns_nil
    seed_agg_add(dfn: "9")
    seed_agg_update
    seed_hrn_41_readback(9, :no_reply)

    result = Reg.register(ATTRS)

    assert_equal :hrn_file_failed, result[:error]
    assert_equal 9, result[:dfn]
  end

  def test_derive_hrn_unverified_when_lister_errors
    seed_agg_add(dfn: "9")
    seed_agg_update
    seed_hrn_41_readback(9, :error)

    result = Reg.register(ATTRS)

    assert_equal :hrn_file_failed, result[:error]
    assert_equal 9, result[:dfn]
  end

  def test_temporary_hrn_success_requires_matching_readback
    seed_agg_add(dfn: "9")
    seed_temp_hrn("T00007")
    seed_agg_update
    seed_hrn_41_readback(9, "T00007")

    result = Reg.register(ATTRS.merge(hrn_source: :temporary))

    assert result[:success]
    assert_equal "T00007", result[:hrn]
    assert_equal 1, hrn_lister_calls.length
  end

  def test_given_hrn_success_requires_matching_readback
    seed_agg_add(dfn: "9")
    seed_hrn_41_readback(9, "12345")

    result = Reg.register(ATTRS.merge(hrn_source: :given, hrn: "12345"))

    assert result[:success]
    assert_equal "12345", result[:hrn]
    assert_equal 1, hrn_lister_calls.length
  end

  def test_clerk_mode_without_hrn_skips_readback
    Reg.hrn_mode = Reg::HRN_MODE_CLERK
    seed_agg_add(dfn: "9")

    result = Reg.register(ATTRS)

    assert result[:success]
    assert_nil result[:hrn]
    assert_empty hrn_lister_calls
  end

  [
    RpmsRpc::Client::ConnectionError,
    RpmsRpc::Client::TimeoutError,
    RpmsRpc::Client::ParseError
  ].each do |error_class|
    define_method("test_derive_hrn_#{error_class.name.split('::').last.downcase}_on_readback_is_hrn_file_failed") do
      seed_agg_add(dfn: "9")
      seed_agg_update
      with_hrn_41_lister_raise(error_class) do
        result = Reg.register(ATTRS)

        refute result[:success]
        assert_equal :hrn_file_failed, result[:error]
        assert_equal 9, result[:dfn]
        assert_equal Reg::HRN_UNREADABLE, result[:message]
        refute_message_leaks_phi(result[:message])
      end
    end
  end
end
