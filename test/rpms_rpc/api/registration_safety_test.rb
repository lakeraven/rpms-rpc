# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc"
require "rpms_rpc/api/patient"
require "rpms_rpc/api/ddr_fileman"
require_relative "../captured_replies"

# Registration.register's duplicate-identity preflight. Every reply is the
# build's (test/fixtures/captured_replies/registration-safety.yml), captured
# as PROFILE,REG on a throwaway container: each register flow filed its
# synthetic patient over CIA, with the duplicate lookup on a BMX session
# signed on as the same user, and each lookup_* flow is that lookup's BMX
# reply on its own (no match; SAFETYDEMO,UNA once, then twice; a different
# name on her birth date; her name on another date). Each register test checks
# the CIA session sent exactly the recorded calls. A lost wire on the lookup
# or a field check is raised by the replay itself. The fault over BMX, and
# the broker's refusal of a user without AGGRPC, are in
# registration_lookup_broker_test.rb.
class RegistrationSafetyTest < Minitest::Test
  Reg = RpmsRpc::Registration
  SLUG = "registration-safety"
  DUZ = "207"
  # A reason for no SSN: AG cannot check a registration with neither (openrpms#1040).
  ATTRS = { name: "SAFETYDEMO,UNA", dob: Date.new(1903, 1, 2), sex: "F", no_ssn_reason: "N" }.freeze
  QUERY = "AGGPTLNM=SAFETYDEMO\x1cAGGPTFNM=UNA\x1cAGGPTMNM=\x1cAGGPTSFX=\x1cAGGPTDOB=01/02/1903"
  REVIEW = { success: false, error: :duplicate_identity, candidate_dfns: [ 990_057 ],
             message: "matching patient candidates require explicit override" }.freeze

  def teardown
    Reg.hrn_mode = Reg::HRN_MODE_DERIVE
    RpmsRpc.reset!
  end

  # The CIA session register runs on: a register flow's replies, else none.
  def session(flow = nil)
    @session = CapturedReplies::ReplayCiaClient.new(flow ? CapturedReplies.flow_script(SLUG, flow) : {}).signed_on_as(DUZ)
    RpmsRpc.configure { |c| c.client = @session }
    @session
  end

  # The BMX session the lookup runs on, signed on as the same user with AGGRPC
  # bound: a lookup flow's replies, else none.
  def lookup(flow = nil, client_class: CapturedReplies::ReplayBmxClient)
    @lookup = client_class.new(flow ? CapturedReplies.flow_script(SLUG, flow) : {})
    @lookup.instance_variable_set(:@authenticated, true)
    @lookup.instance_variable_set(:@duz, DUZ)
    @lookup.instance_variable_set(:@current_context, RpmsRpc::Agg::CONTEXT)
    @lookup
  end

  def register(attrs, cia: nil, bmx: nil)
    session(cia)
    Reg.with_lookup_client(lookup(bmx)) { Reg.register(attrs) }
  end

  def sent = @session.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params] ] }

  def lookups = @lookup.calls.select { |c| c[:rpc] == "AGG LOOKUP PATIENTS" }

  # The one lookup register sent.
  def the_lookup
    assert_equal 1, lookups.size, "expected one duplicate lookup"
    lookups.first
  end

  # AG's field checks run on the CIA session before the lookup; nothing else
  # may be sent when the lookup stops the registration.
  def assert_no_write
    assert_equal [ "AGG WINDOW DATA VALIDATION" ], sent.map(&:first).uniq
  end

  def test_second_registration_refuses_and_only_one_patient_is_added
    assert_equal({ success: true, dfn: 990_057, created: true, hrn: "990057" },
                 register(ATTRS, cia: "register_first", bmx: "lookup_first"))
    assert_equal CapturedReplies.flow_calls(SLUG, "register_first"), sent
    assert_equal [ QUERY, "", "1", "1" ], the_lookup[:params]
    assert_equal "CIAV VUECENTRIC", @session.current_context

    assert_equal REVIEW, register(ATTRS, cia: "register_override", bmx: "lookup_second")
    assert_no_write
  end

  # Both SAFETYDEMO,UNA charts are listed, in DFN order.
  def test_every_candidate_is_listed_without_demographics
    assert_equal REVIEW.merge(candidate_dfns: [ 990_057, 990_058 ]),
                 register(ATTRS, cia: "register_override", bmx: "lookup_both")
    assert_no_write
  end

  def test_explicit_boolean_override_allows_add_but_still_looks_up
    result = register(ATTRS.merge(allow_duplicate: true), cia: "register_override", bmx: "lookup_second")

    assert_equal({ success: true, dfn: 990_058, created: true, hrn: "990058" }, result)
    refute_empty lookups
    assert_equal CapturedReplies.flow_calls(SLUG, "register_override"), sent
  end

  [ "true", "false", 1, nil, false ].each_with_index do |override, i|
    define_method("test_non_boolean_override_#{i}_does_not_authorize_add") do
      result = register(ATTRS.merge(allow_duplicate: override), cia: "register_override", bmx: "lookup_second")

      assert_equal :duplicate_identity, result[:error]
      assert_no_write
    end
  end

  # The server searches by name OR DOB. A DOB disagreement cannot rule out
  # name resolution in ADD^AGGPTADD, and a name disagreement is for review.
  { name: [ "lookup_other_name", { name: "SAFETYOTHER,BOB", sex: "M" } ],
    dob: [ "lookup_other_dob", { dob: Date.new(1903, 1, 3) } ] }.each do |field, (flow, change)|
    define_method("test_candidate_with_different_#{field}_still_requires_review") do
      assert_equal REVIEW.merge(candidate_dfns: [ 990_057, 990_058 ]),
                   register(ATTRS.merge(change), cia: "register_override", bmx: flow)
      assert_equal CapturedReplies.flow_calls(SLUG, flow).last.last, the_lookup[:params]
      assert_no_write
    end
  end

  { last_name: { name: ",UNA" }, first_name: { name: "SAFETYDEMO," },
    dob: { dob: " " }, sex: { sex: " " } }.each do |field, change|
    define_method("test_missing_#{field}_refuses_with_exact_field_name") do
      assert_equal({ success: false, error: :identity_unverifiable,
                     message: "patient identity missing or invalid: #{field}" }, register(ATTRS.merge(change)))
      assert_empty @session.calls
      assert_empty @lookup.calls
    end
  end

  [ "2/30/1903", "1/2/03garbage", "TODAY" ].each_with_index do |date, i|
    define_method("test_invalid_dob_#{i}_refuses") do
      assert_equal({ success: false, error: :identity_unverifiable,
                     message: "patient identity missing or invalid: dob" }, register(ATTRS.merge(dob: date)))
      assert_empty @session.calls
      assert_empty @lookup.calls
    end
  end

  [ "1/2/1903", " 1/2/1903 ", "1903-01-02", "2030102", "JAN 02, 1903" ].each_with_index do |dob, i|
    define_method("test_equivalent_dob_#{i}_uses_the_same_lookup_and_add_date") do
      assert register(ATTRS.merge(dob: dob), cia: "register_first", bmx: "lookup_first")[:success]

      assert_equal QUERY, the_lookup[:params].first
      assert_equal CapturedReplies.flow_calls(SLUG, "register_first"), sent
    end
  end

  def test_name_pieces_used_for_both_lookup_and_add
    attrs = { name_last: " safetypieces ", name_first: " una ", name_middle: "MAE", name_suffix: "JR",
              dob: Date.new(1903, 2, 2), sex: "F", no_ssn_reason: "N" }

    assert register(attrs, cia: "register_pieces", bmx: "lookup_pieces")[:success]
    assert_equal "AGGPTLNM=SAFETYPIECES\x1cAGGPTFNM=UNA\x1cAGGPTMNM=MAE\x1cAGGPTSFX=JR\x1cAGGPTDOB=02/02/1903",
                 the_lookup[:params].first
    assert_equal CapturedReplies.flow_calls(SLUG, "register_pieces"), sent
  end

  # The wire to the lookup is lost: unverifiable, and the error (which can
  # carry the patient's details) is not echoed.
  [ RpmsRpc::Client::RpcError, RpmsRpc::Client::ConnectionError ].each_with_index do |error, i|
    define_method("test_failed_lookup_#{i}_refuses_without_echoing_error") do
      failing = Class.new(CapturedReplies::ReplayBmxClient) do
        define_method(:build_bmx_message) do |rpc_name, *rest|
          raise error, "SAFETYDEMO,UNA 01/02/1903" if rpc_name == "AGG LOOKUP PATIENTS"

          super(rpc_name, *rest)
        end
      end
      session("register_first")
      result = Reg.with_lookup_client(lookup(client_class: failing)) { Reg.register(ATTRS) }

      assert_equal({ success: false, error: :identity_unverifiable,
                     message: "patient duplicate lookup could not be verified" }, result)
      assert_no_write
    end
  end

  def test_context_failure_never_falls_back_to_another_write_path
    refusing = Class.new(CapturedReplies::ReplayCiaClient) do
      def create_context(option_name = SIGNON_CONTEXT)
        raise RpmsRpc::Client::RpcError, "context refused" if option_name == RpmsRpc::Agg::CONTEXT

        super
      end
    end
    @session = refusing.new({}).signed_on_as(DUZ)
    RpmsRpc.configure { |c| c.client = @session }

    # AG's field checks are the first AGGRPC call, so they meet the failure first.
    assert_equal :validation_unavailable, Reg.with_lookup_client(lookup) { Reg.register(ATTRS) }[:error]
    assert_empty sent
    assert_empty @lookup.calls
  end

  def test_parameter_delimiter_cannot_change_identity_after_lookup
    assert_raises(ArgumentError) { register(ATTRS.merge(tribe: "123\x1cAGGPTLNM=OTHERDEMO")) }
    assert_empty @session.calls
    assert_empty @lookup.calls
  end

  # A field check whose wire is lost is not a pass: nothing is filed, and the
  # error (which can carry the patient's details) is not echoed.
  [ RpmsRpc::Client::RpcError, RpmsRpc::Client::ConnectionError ].each_with_index do |error, i|
    define_method("test_failed_field_check_#{i}_refuses_without_echoing_error") do
      failing = Class.new(CapturedReplies::ReplayCiaClient) do
        define_method(:call_rpc_raw) do |rpc_name, *params|
          raise error, "SAFETYDEMO,UNA 01/02/1903" if rpc_name == "AGG WINDOW DATA VALIDATION"

          super(rpc_name, *params)
        end
      end
      @session = failing.new(CapturedReplies.flow_script(SLUG, "register_first")).signed_on_as(DUZ)
      RpmsRpc.configure { |c| c.client = @session }

      result = Reg.with_lookup_client(lookup("lookup_first")) { Reg.register(ATTRS) }

      assert_equal :validation_unavailable, result[:error]
      refute_includes result[:message], "1903"
      assert_empty lookups
    end
  end
end
