# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/cia_client"
require "rpms_rpc/xwb_client"
require "rpms_rpc/bmx_client"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/patient"
require "rpms_rpc/api/problem"
require "rpms_rpc/api/referral"

# A missing RPC raises a typed error; it is never guarded into "no data"
# (rpms-rpc#363, ADR 0010 assertions 1 and 4).
#
# Every broker words its errors its own way. All three transports raise the
# same class for the same case, kept distinct so a host can tell them apart:
# RpcNotAvailableError when the server does not serve the RPC (404/501-like),
# RpcRefusedError when it serves it but not to this user in the bound option
# (403-like), RpcError for an M error from a routine that ran (500-like).
# The live half of this contract is test/live/missing_rpc_live_test.rb.
class MissingRpcRaisesTest < Minitest::Test
  NotAvailable = RpmsRpc::Client::RpcNotAvailableError
  Refused = RpmsRpc::Client::RpcRefusedError

  def teardown
    RpmsRpc.reset!
  end

  # -- the typed error -------------------------------------------------------

  def test_not_available_and_refused_are_distinct_rpc_errors
    assert_operator NotAvailable, :<, RpmsRpc::Client::RpcError
    assert_operator Refused, :<, RpmsRpc::Client::RpcError
    refute_operator NotAvailable, :<=, Refused
    refute_operator Refused, :<=, NotAvailable
  end

  def test_inactive_rpc_is_not_available
    assert_equal NotAvailable, RpmsRpc::Client.rpc_error_for("Remote Procedure 'X' cannot be run at this time.")
  end

  # -- CIA: CIANBACT error 3 (no #8994 entry) and 4 ($$CANRUN false) --------

  def test_cia_unknown_remote_procedure_raises_not_available
    err = assert_raises(NotAvailable) { cia_parse("2\x013 Unknown remote procedure: ZZZ NO SUCH RPC") }
    assert_includes err.message, "ZZZ NO SUCH RPC"
  end

  def test_cia_access_denied_raises_refused
    assert_raises(Refused) { cia_parse("2\x014 Access denied for remote procedure: BMC PROVIDERS") }
  end

  def test_cia_m_error_is_an_rpc_error_but_not_not_available
    err = assert_raises(RpmsRpc::Client::RpcError) do
      cia_parse("2\x011 The server has reported the following error: DETAIL+3^ORQQPL, Undefined local variable")
    end
    refute_kind_of NotAvailable, err
    refute_kind_of Refused, err
  end

  # -- XWB: the refusal is the SNDERR security packet (XWBPRS.m:11-13) ------

  def test_xwb_unregistered_rpc_raises_not_available
    err = assert_raises(NotAvailable) { xwb_call(snderr(sec: "Remote Procedure 'ZZZ NO SUCH RPC' doesn't exist on the server.")) }
    assert_includes err.message, "ZZZ NO SUCH RPC"
  end

  # The length byte of the security packet is printable for some names (69
  # is "E"); the refusal must not depend on which.
  def test_xwb_unregistered_rpc_raises_not_available_for_any_name_length
    (1..40).each do |n|
      name = "Z" * n
      assert_raises(NotAvailable, name) { xwb_call(snderr(sec: "Remote Procedure '#{name}' doesn't exist on the server.")) }
    end
  end

  def test_xwb_rpc_outside_the_context_option_raises_refused
    assert_raises(Refused) do
      xwb_call(snderr(sec: "The remote procedure ORWU USERKEYS is not registered to the option OR CPRS GUI CHART."))
    end
  end

  def test_xwb_application_error_packet_is_an_rpc_error_but_not_not_available
    err = assert_raises(RpmsRpc::Client::RpcError) { xwb_call(snderr(err: "M  ERROR=<UNDEFINED>FOO+5^BAR^")) }
    refute_kind_of NotAvailable, err
    refute_kind_of Refused, err
  end

  def test_xwb_data_reply_is_lines
    assert_equal %w[1^A 2^B], xwb_call(snderr(data: "1^A\r\n2^B\r\n"))
  end

  # -- BMX: the same refusal arrives as the security packet (BMXMBRK.m:157) -

  def test_bmx_unregistered_rpc_raises_not_available
    assert_raises(NotAvailable) { bmx_read(snderr(sec: "Remote Procedure 'ZZZ NO SUCH RPC' doesn't exist on the server.")) }
  end

  def test_bmx_context_not_created_raises_refused
    assert_raises(Refused) { bmx_read(snderr(sec: "Application context has not been created!")) }
  end

  def test_bmx_other_security_error_stays_a_connection_error
    assert_raises(RpmsRpc::Client::ConnectionError) { bmx_read(snderr(sec: "Not a valid ACCESS CODE/VERIFY CODE pair.")) }
  end

  # -- no capability probe ---------------------------------------------------

  def test_there_is_no_capability_probe
    refute RpmsRpc.const_defined?(:ServerCapabilities, false), "ServerCapabilities is removed (#363)"
    refute RpmsRpc::Client.method_defined?(:supports?), "Client#supports? is removed (#363)"
    refute RpmsRpc::MockClient.method_defined?(:supports?), "MockClient#supports? is removed (#363)"
  end

  def test_no_api_method_asks_supports
    api = Dir[File.expand_path("../../lib/rpms_rpc/api/**/*.rb", __dir__)]
    guarded = api.select { |f| File.read(f).match?(/\bsupports\?/) }.map { |f| File.basename(f) }
    assert_empty guarded, "API files still guard on supports?"
  end

  # -- the formerly guarded methods raise, not return empty ------------------

  # A broker that refuses every RPC the way CIA does when it is not served.
  class RefusingClient
    attr_reader :calls

    def initialize = @calls = []

    %i[call_rpc call_rpc_lines].each do |m|
      define_method(m) do |rpc, *|
        @calls << rpc
        raise RpmsRpc::Client::RpcNotAvailableError, "3 Unknown remote procedure: #{rpc}"
      end
    end
  end

  FORMERLY_GUARDED = {
    "Patient.brief_header" => -> { RpmsRpc::Patient.brief_header(8791) },
    "Problem.lex_search" => -> { RpmsRpc::Problem.lex_search("diabetes") },
    "Problem.clinic_search" => -> { RpmsRpc::Problem.clinic_search(7) },
    "Problem.details" => -> { RpmsRpc::Problem.details(8791, 5001) },
    "Problem.audit_history" => -> { RpmsRpc::Problem.audit_history(5001) },
    "Problem.comments" => -> { RpmsRpc::Problem.comments(5001) },
    "Problem.init_patient" => -> { RpmsRpc::Problem.init_patient(8791) },
    "Problem.provider_list" => -> { RpmsRpc::Problem.provider_list(8791) },
    "Problem.edit_load" => -> { RpmsRpc::Problem.edit_load(5001) },
    "Problem.inactivate" => -> { RpmsRpc::Problem.inactivate(5001) },
    "Problem.verify" => -> { RpmsRpc::Problem.verify(5001) },
    "Referral.add" => -> { RpmsRpc::Referral.add("1") },
    "Referral.update" => -> { RpmsRpc::Referral.update("1", "x") },
    "Referral.print" => -> { RpmsRpc::Referral.print("1") },
    "Referral.update_status" => -> { RpmsRpc::Referral.update_status("1", "A") },
    "Referral.update_consultation_status" => -> { RpmsRpc::Referral.update_consultation_status("1", "A") },
    "Referral.purposes" => -> { RpmsRpc::Referral.purposes },
    "Referral.reference_data" => -> { RpmsRpc::Referral.reference_data },
    "Referral.users_providers" => -> { RpmsRpc::Referral.users_providers },
    "Referral.providers" => -> { RpmsRpc::Referral.providers("A") },
    "Referral.search_referred_to" => -> { RpmsRpc::Referral.search_referred_to("A") },
    "Referral.rcis_templates" => -> { RpmsRpc::Referral.rcis_templates },
    "Referral.rcis_template_detail" => -> { RpmsRpc::Referral.rcis_template_detail(1) },
    "Referral.patient_eligibility_status" => -> { RpmsRpc::Referral.patient_eligibility_status(8791) },
    "Referral.patient_face_sheet" => -> { RpmsRpc::Referral.patient_face_sheet(8791) },
    "Referral.patient_health_summary" => -> { RpmsRpc::Referral.patient_health_summary(8791) },
    "Referral.health_summary_types" => -> { RpmsRpc::Referral.health_summary_types },
    "Referral.check_year_site_param" => -> { RpmsRpc::Referral.check_year_site_param },
    "Referral.add_c32_print_log" => -> { RpmsRpc::Referral.add_c32_print_log("1") }
  }.freeze

  def test_each_formerly_guarded_method_sends_its_rpc_and_raises_the_refusal
    FORMERLY_GUARDED.each do |name, call|
      client = RefusingClient.new
      RpmsRpc.reset!
      RpmsRpc.configure { |cfg| cfg.client = client }

      assert_raises(NotAvailable, "#{name} must raise, not answer empty") { call.call }
      refute_empty client.calls, "#{name} sent no RPC"
    end
  end

  def test_without_a_configured_client_a_formerly_guarded_method_raises
    RpmsRpc.reset!
    assert_raises(RpmsRpc::NotConfiguredError) { RpmsRpc::Problem.lex_search("diabetes") }
  end

  private

  # One CIA reply (sequence echo + flag + body), parsed the way call_rpc does.
  def cia_parse(raw)
    RpmsRpc::CiaClient.new.send(:parse_cia_reply, raw.b)
  end

  # XWB SNDERR framing (XWBRW.m:70-78): security packet, then application
  # packet, each a length byte + text, then the data.
  def snderr(sec: "", err: "", data: "")
    (sec.length.chr + sec + err.length.chr + err + data).b
  end

  def xwb_call(raw)
    c = RpmsRpc::XwbClient.new
    c.instance_variable_set(:@connected, true)
    c.instance_variable_set(:@socket, Object.new.tap { |s| s.define_singleton_method(:closed?) { false } })
    c.define_singleton_method(:wire_operation) { |**_kw, &blk| blk.call }
    c.define_singleton_method(:send_packet) { |_p| nil }
    c.define_singleton_method(:read_until_eot_raw) { raw.dup }
    c.call_rpc("ANY RPC")
  end

  def bmx_read(raw)
    c = RpmsRpc::BmxClient.new
    c.define_singleton_method(:read_until_eot_raw) { raw.dup }
    c.send(:read_response)
  end
end
