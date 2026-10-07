# frozen_string_literal: true

require_relative "live_helper"
require "rpms_rpc/api/patient"
require "rpms_rpc/api/problem"
require "rpms_rpc/api/ddr_fileman"
require "rpms_rpc/api/referral"
require "rpms_rpc/api/scheduling"

# A missing RPC raises a typed error; no API method guards it into "no data"
# (#363, ADR 0010 assertions 1 and 4).
#
# The CIA broker refuses an RPC it will not run for this session before any
# routine runs, and the two refusals stay distinct: error 3, no #8994 entry,
# raises Client::RpcNotAvailableError (the server does not serve it,
# 404/501-like); error 4, $$CANRUN^CIANBACT false for this user in the bound
# option (CIANBACT.m:49), raises Client::RpcRefusedError (served, not to
# you, 403-like). An M error from a routine that ran is a plain RpcError.
#
# Each method below was guarded by a capability probe until #363 and now
# calls its RPC unconditionally. Its spec asks the broker first, through
# CIANBRPC CANRUN (the same $$CANRUN the refusal is decided by), whether this
# persona may run the RPC IN THE OPTION THE METHOD BINDS, and then:
#
#   - may not: the method raises RpcRefusedError. Safe for writes too,
#     since the refusal comes before the routine.
#   - may, a read: the method answers. The methods in KNOWN_BINDING_BUGS
#     instead reach their routine and fail with an M error (an RpcError
#     that is not RpcNotAvailableError): served, and a binding to fix
#     (#364). Each is listed by name, and its spec fails when it starts
#     answering, so the list only shrinks.
#   - may, a write: CANRUN's answer is the proof. The spec does not call it,
#     so nothing is filed.
#
# The option is the method's, not the sign-on's. CIANBRPC CANRUN answers
# for the CTX on its own frame (CANRUN^CIANBRPC passes CIA("CTX") to
# $$CANRUN^CIANBACT), and a module that declares a CONTEXT binds it around
# every RPC it sends (ContextScope.scoped): Referral binds BMCRPC, Scheduling
# BSDXRPC. A module that declares none (Patient, Problem) runs under the
# sign-on option, CIAV VUECENTRIC. So the oracle binds the same option the
# method will before it asks.
#
# These specs read only; they file nothing.
class MissingRpcLiveTest < LiveSpec::Test
  NotAvailable = RpmsRpc::Client::RpcNotAvailableError
  Refused = RpmsRpc::Client::RpcRefusedError

  # Registered on no pinned registry (#207); the gem no longer sends it.
  UNREGISTERED_RPC = "ORWU USERKEYS"
  CANRUN_RPC = "CIANBRPC CANRUN"
  SIGNON_CONTEXT = RpmsRpc::CiaClient::SIGNON_CONTEXT

  # Registered reads that the sign-on option CIAV VUECENTRIC does not list for
  # the provider persona: refused, not missing.
  HOSPITAL_LOCATION_RPC = "BSDX HOSPITAL LOCATION"
  IS_RPC_AVAILABLE_RPC = "XWB IS RPC AVAILABLE"

  DFN = 4 # DEMO,PATIENT ONE on the pinned build (patient_live_test.rb)
  PROBLEM_IEN = 1
  CLINIC_IEN = 7

  # Served, but the routine fails with an M error on the pinned build (#364),
  # for both personas, under the option the method binds:
  #   Referral.purposes            SUBLST+5, QUIT does not return to an extrinsic
  #   Referral.reference_data      S4+12^DICL2, command expected
  #   Referral.providers           PROV^ORQPTQ2, more actual than formal parameters
  #   Referral.search_referred_to  SRRFRDTO+3^BMCRPC1, QUIT does not return to an extrinsic
  #   Referral.rcis_templates      GTTMPLST+9^BMCRPC3, QUIT does not return to an extrinsic
  KNOWN_BINDING_BUGS = %w[
    Referral.purposes Referral.reference_data Referral.providers
    Referral.search_referred_to Referral.rcis_templates
  ].freeze

  # method => [kind, RPCs it sends, the call]. The call runs on the test
  # instance (instance_exec), so it may use `client` and the helpers below.
  FORMERLY_GUARDED = {
    "Patient.brief_header" => [ :read, [ "BEHOPTCX PTINFO", "BEHOPTPC GETBDP", "BEHOCACV CWAD" ], -> { RpmsRpc::Patient.brief_header(DFN) } ],
    "Problem.lex_search" => [ :read, [ "ORQQPL PROBLEM LEX SEARCH" ], -> { RpmsRpc::Problem.lex_search("diabetes") } ],
    "Problem.clinic_search" => [ :read, [ "ORQQPL CLIN SRCH" ], -> { RpmsRpc::Problem.clinic_search(CLINIC_IEN) } ],
    "Problem.details" => [ :read, [ "ORQQPL DETAIL" ], -> { RpmsRpc::Problem.details(DFN, PROBLEM_IEN) } ],
    "Problem.audit_history" => [ :read, [ "ORQQPL AUDIT HIST" ], -> { RpmsRpc::Problem.audit_history(PROBLEM_IEN) } ],
    "Problem.comments" => [ :read, [ "ORQQPL PROB COMMENTS" ], -> { RpmsRpc::Problem.comments(PROBLEM_IEN) } ],
    "Problem.init_patient" => [ :read, [ "ORQQPL INIT PT" ], -> { RpmsRpc::Problem.init_patient(DFN) } ],
    "Problem.provider_list" => [ :read, [ "ORQQPL PROVIDER LIST" ], -> { RpmsRpc::Problem.provider_list(DFN) } ],
    "Problem.edit_load" => [ :read, [ "ORQQPL EDIT LOAD" ], -> { RpmsRpc::Problem.edit_load(PROBLEM_IEN, provider_duz: client.duz, institution_ien: institution_ien) } ],
    "Problem.inactivate" => [ :write, [ "ORQQPL INACTIVATE" ], -> { RpmsRpc::Problem.inactivate(PROBLEM_IEN) } ],
    "Problem.verify" => [ :write, [ "ORQQPL VERIFY" ], -> { RpmsRpc::Problem.verify(PROBLEM_IEN) } ],
    "Referral.purposes" => [ :read, [ "BMC GET PURPOSE OF REF API" ], -> { RpmsRpc::Referral.purposes } ],
    "Referral.reference_data" => [ :read, [ "BMC GET REFERENCE DATA" ], -> { RpmsRpc::Referral.reference_data } ],
    "Referral.users_providers" => [ :read, [ "BMC GET USERS/PROVIDERS" ], -> { RpmsRpc::Referral.users_providers } ],
    "Referral.providers" => [ :read, [ "BMC PROVIDERS" ], -> { RpmsRpc::Referral.providers("A") } ],
    "Referral.search_referred_to" => [ :read, [ "BMC SEARCH REFERRED TO" ], -> { RpmsRpc::Referral.search_referred_to("A") } ],
    "Referral.rcis_templates" => [ :read, [ "BMC GET RCIS TEMPLATE LIST" ], -> { RpmsRpc::Referral.rcis_templates } ],
    "Referral.rcis_template_detail" => [ :read, [ "BMC GET RCIS TEMPLATE DETAIL" ], -> { RpmsRpc::Referral.rcis_template_detail(1) } ],
    "Referral.patient_eligibility_status" => [ :read, [ "BMC PATIENT ELIGIBILITY STATUS" ], -> { RpmsRpc::Referral.patient_eligibility_status(DFN) } ],
    "Referral.patient_face_sheet" => [ :read, [ "BMC PATIENT FACE SHEET" ], -> { RpmsRpc::Referral.patient_face_sheet(DFN) } ],
    "Referral.patient_health_summary" => [ :read, [ "BMC PATIENT HEALTH SUMMARY" ], -> { RpmsRpc::Referral.patient_health_summary(DFN) } ],
    "Referral.health_summary_types" => [ :read, [ "BMC HEALTH SUMMARY TYPE" ], -> { RpmsRpc::Referral.health_summary_types } ],
    "Referral.add" => [ :write, [ "BMC ADD REFERRAL" ], -> { RpmsRpc::Referral.add } ],
    "Referral.update" => [ :write, [ "BMC UPDATE REFERRAL" ], -> { RpmsRpc::Referral.update("0") } ],
    "Referral.print" => [ :write, [ "BMC PRINT REFERRAL" ], -> { RpmsRpc::Referral.print("0") } ],
    "Referral.update_status" => [ :write, [ "BMC REFERRAL STATUS UPDATE" ], -> { RpmsRpc::Referral.update_status("0", "") } ],
    "Referral.update_consultation_status" => [ :write, [ "BMC CONSULTATION STATUS UPDATE" ], -> { RpmsRpc::Referral.update_consultation_status("0", "") } ],
    "Referral.check_year_site_param" => [ :write, [ "BMC CHK YEAR SITE PARAM" ], -> { RpmsRpc::Referral.check_year_site_param } ],
    "Referral.add_c32_print_log" => [ :write, [ "BMC ADD C32 PRINT LOG" ], -> { RpmsRpc::Referral.add_c32_print_log } ]
  }.freeze

  def test_an_rpc_the_build_does_not_register_raises_not_available
    err = assert_raises(NotAvailable) { client.call_rpc(UNREGISTERED_RPC, client.duz.to_s) }
    assert_match(/Unknown remote procedure: #{UNREGISTERED_RPC}/, err.message)
    refute canrun?(UNREGISTERED_RPC), "CANRUN says yes to an RPC #8994 does not hold"
  end

  def test_an_unregistered_rpc_is_not_refused_but_not_available
    err = assert_raises(RpmsRpc::Client::RpcError) { client.call_rpc(UNREGISTERED_RPC) }
    assert_instance_of NotAvailable, err
  end

  # Sent bare, under the sign-on option, which does not list it.
  def test_a_registered_rpc_outside_the_option_is_refused_not_missing
    if canrun?(HOSPITAL_LOCATION_RPC)
      refute_empty client.call_rpc(HOSPITAL_LOCATION_RPC), "#{persona} may run #{HOSPITAL_LOCATION_RPC}; it answered no clinics"
    else
      err = assert_raises(Refused) { client.call_rpc(HOSPITAL_LOCATION_RPC) }
      assert_match(/Access denied for remote procedure: #{HOSPITAL_LOCATION_RPC}/, err.message)
    end
  end

  # The same RPC through the API, which binds BSDXRPC, the option that lists it.
  def test_scheduling_hospital_locations_binds_the_option_that_lists_its_rpc
    if canrun?(HOSPITAL_LOCATION_RPC, RpmsRpc::Scheduling::CONTEXT)
      refute_empty RpmsRpc::Scheduling.hospital_locations, "#{persona} may run #{HOSPITAL_LOCATION_RPC} in BSDXRPC; it answered no clinics"
    else
      err = assert_raises(Refused) { RpmsRpc::Scheduling.hospital_locations }
      assert_match(/Access denied for remote procedure: #{HOSPITAL_LOCATION_RPC}/, err.message)
    end
  end

  def test_xwb_is_rpc_available_over_cia_is_refused_or_answers
    if canrun?(IS_RPC_AVAILABLE_RPC)
      refute_empty client.call_rpc(IS_RPC_AVAILABLE_RPC, "ORWPT LIST ALL"), "#{persona} may run #{IS_RPC_AVAILABLE_RPC}; it answered nothing"
    else
      err = assert_raises(Refused) { client.call_rpc(IS_RPC_AVAILABLE_RPC, "ORWPT LIST ALL") }
      assert_match(/Access denied for remote procedure: #{IS_RPC_AVAILABLE_RPC}/, err.message)
    end
  end

  def test_the_refusal_leaves_the_session_usable
    assert_raises(NotAvailable) { client.call_rpc(UNREGISTERED_RPC) }
    assert_operator RpmsRpc::Problem.lex_search("diabetes").size, :>, 0, "the next RPC on the session did not answer"
  end

  FORMERLY_GUARDED.each do |name, (kind, rpcs, call)|
    define_method("test_#{name.downcase.tr('.', '_')}_answers_or_raises_never_empty") do
      context = bound_context(name)
      denied = rpcs.reject { |rpc| canrun?(rpc, context) }

      if denied.any?
        err = assert_raises(Refused, "#{name} as #{persona}: #{denied.join(', ')} refused in #{context}, so it must raise") { instance_exec(&call) }
        assert_match(/Access denied for remote procedure/, err.message)
      elsif kind == :write
        pass # CANRUN says this persona may run every RPC it sends; not called, so nothing is filed.
      else
        assert_served(name) { instance_exec(&call) }
      end
    end
  end

  private

  # $$CANRUN^CIANBACT for this RPC in `context`, without running it. The
  # frame carries `context` as its CTX, which is the option CANRUN asks about
  # (CIANBRPC.m:174); the sign-on option is restored afterward. It answers $D
  # of the context node (CIANBACT.m:148): 1, 10 or 11 when the option lists
  # the RPC (10 for the provider persona), 0 when not.
  def canrun?(rpc, context = SIGNON_CONTEXT)
    RpmsRpc::ContextScope.scoped(client, context) do
      client.call_rpc(CANRUN_RPC, rpc).first.to_i.positive?
    end
  end

  # The option `name` ("Module.method") binds for its RPCs: its module's
  # CONTEXT, which the module binds around every RPC it sends, or the sign-on
  # option when it declares none.
  def bound_context(name)
    mod = RpmsRpc.const_get(name.split(".").first, false)
    mod.const_defined?(:CONTEXT, false) ? mod::CONTEXT : SIGNON_CONTEXT
  end

  # The facility EDLOAD^ORQQPL1 wants as GMPVAMC: the INSTITUTION (#4) the
  # build's first MEDICAL CENTER DIVISION (#40.8) points at (field .07), as
  # organization_find_live_test.rb reads it. DDR LISTER is in the sign-on
  # option.
  def institution_ien
    divisions = RpmsRpc::DdrFileman.lister(file: 40.8, fields: "@;.07I", max: 5)
    flunk "DDR LISTER on #40.8 answered nothing or with errors: #{divisions.inspect}" if divisions.nil? || divisions[:error]
    ien = divisions[:entries].map { |e| e[:pieces][0] }.find { |v| v.to_s.match?(/\A\d+\z/) }
    flunk "no MEDICAL CENTER DIVISION (#40.8) points at an institution (field .07)" if ien.nil?
    ien
  end

  def assert_served(name)
    yield
    refute_includes KNOWN_BINDING_BUGS, name, "#{name} as #{persona} answers now: drop it from KNOWN_BINDING_BUGS and #364"
  rescue NotAvailable, Refused => e
    flunk "#{name} as #{persona}: CANRUN said yes, yet the broker said #{e.class}: #{e.message}"
  rescue RpmsRpc::Client::RpcError => e
    assert_includes KNOWN_BINDING_BUGS, name, "#{name} as #{persona} reached its routine and failed: #{e.message[0, 160]}"
  end
end
