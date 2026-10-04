# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/referral"

class ReferralTest < Minitest::Test
  DFN = "8791"

  def teardown
    RpmsRpc.reset!
  end

  # Referral.create is honestly :not_implemented (#217): its former binding
  # BGOREF SET is the personal REFUSALS writer (SET^BGOREF files ^AUPNPREF —
  # BGOREF.m:8,29), and the real referral writer (BMC ADD REFERRAL =
  # SETREFRL^BMCRPC2, 39 positional formals) is exposed as Referral.add.

  def test_create_is_not_implemented_and_calls_no_rpc
    RpmsRpc.mock!

    result = RpmsRpc::Referral.create(DFN, { specialty: "CARDIOLOGY" })

    refute result[:success]
    assert_equal :not_implemented, result[:error]
    assert_match(/BGOREF SET writes refusals/, result[:message])
    assert_empty RpmsRpc.client.received_calls,
      "create must not touch the broker — BGOREF SET would file a refusal"
  end

  def test_create_raises_on_non_hash_params
    err = assert_raises(ArgumentError) { RpmsRpc::Referral.create(DFN, "not a hash") }
    assert_match(/must be a Hash/, err.message)
  end

  def test_create_blank_dfn_returns_failure
    result = RpmsRpc::Referral.create(nil, { provider_ien: 1 })
    refute result[:success]
    assert_nil result[:ien]
  end

  def test_add_referral_calls_bmc_add_referral
    RpmsRpc.mock! do |m|
      m.seed_scalar(:bmc_add_referral, "8791", "1^3001")
    end

    result = RpmsRpc::Referral.add(DFN, "44")

    assert result[:success]
    assert_equal "3001", result[:message]
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BMC ADD REFERRAL" }
    assert_equal [ DFN, "44" ], call[:params]
  end

  def test_add_referral_bare_ien_response_preserves_value
    # A BMC RPC that returns a bare IEN like "10" (no STATUS^MESSAGE caret)
    # must not be parsed as `message: "0"`. Only strip a leading 0/1 when
    # followed by `^`.
    RpmsRpc.mock! do |m|
      m.seed_scalar(:bmc_add_referral, "8791", "10")
    end

    result = RpmsRpc::Referral.add(DFN, "44")

    assert result[:success]
    assert_equal "10", result[:message]
  end

  def test_update_referral_status_calls_bmc_status_rpc
    RpmsRpc.mock! do |m|
      m.seed_scalar(:bmc_referral_status_update, "3001", "1^UPDATED")
    end

    result = RpmsRpc::Referral.update_status(3001, "APPROVED", "routine")

    assert result[:success]
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BMC REFERRAL STATUS UPDATE" }
    assert_equal [ "3001", "APPROVED", "routine" ], call[:params]
  end

  def test_reference_data_returns_bmc_lookup_rows
    RpmsRpc.mock! do |m|
      m.seed_collection(:bmc_reference_data, [
        { ien: "10", name: "CARDIOLOGY", code: "CARD" }
      ])
    end

    rows = RpmsRpc::Referral.reference_data("PURPOSE")

    assert_equal 1, rows.length
    assert_equal({ ien: "10", name: "CARDIOLOGY", code: "CARD" }, rows.first)
    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BMC GET REFERENCE DATA" }
    assert_equal [ "PURPOSE" ], call[:params]
  end

  def test_rcis_template_detail_returns_text_blob
    RpmsRpc.mock! do |m|
      m.seed_text(:bmc_rcis_template_detail, "7", "line one\nline two")
    end

    assert_equal "line one\nline two", RpmsRpc::Referral.rcis_template_detail(7)
  end

  # GTPTELST^BMCRPC4 (BMCRPC4.m:129): ELIGIBILITY STATUS (external) ^ preferred name.
  def test_patient_eligibility_status_reads_the_status_text_and_preferred_name
    RpmsRpc.mock! do |m|
      m.seed_scalar(:bmc_patient_eligibility_status, DFN, "CHS & DIRECT^JO")
    end

    result = RpmsRpc::Referral.patient_eligibility_status(DFN)

    assert_equal "CHS & DIRECT", result[:status]
    assert_equal "JO", result[:preferred_name]
    refute result.key?(:eligible), "the routine returns no eligible flag"
  end

  # PROV^BMCRPC4 (BMCRPC4.m:136-141): one node, "-1^All~" then IEN^NAME~ per user.
  def test_users_providers_parses_the_single_tilde_node
    RpmsRpc.mock! do |m|
      m.seed_text(:bmc_users_providers, "1", "-1^All~17^DOCTOR,ONE~42^NURSE,TWO~")
    end

    assert_equal [ { ien: "17", name: "DOCTOR,ONE" }, { ien: "42", name: "NURSE,TWO" } ],
                 RpmsRpc::Referral.users_providers(1)
  end

  # SETREFRL^BMCRPC2 (BMCRPC2.m:155): success is "~`1^IEN".
  def test_add_referral_sigil_success_is_success_with_the_ien
    RpmsRpc.mock! do |m|
      m.seed_scalar(:bmc_add_referral, DFN, "~`1^3001")
    end

    result = RpmsRpc::Referral.add(DFN, "44")

    assert result[:success]
    assert_equal "3001", result[:ien]
  end

  # SETREFRL^BMCRPC2 (BMCRPC2.m:58): failure is "~`0^message".
  def test_add_referral_sigil_failure_carries_the_message
    RpmsRpc.mock! do |m|
      m.seed_scalar(:bmc_add_referral, DFN, "~`0^Required field missing")
    end

    result = RpmsRpc::Referral.add(DFN, "44")

    refute result[:success]
    assert_equal "Required field missing", result[:message]
  end

  def test_bmc_calls_short_circuit_when_capability_unsupported
    RpmsRpc.mock! do |m|
      m.seed_capability(:bmc_referral_workflow, supported: false)
      m.seed_scalar(:bmc_add_referral, DFN, "1^3001")
      m.seed_collection(:bmc_reference_data, [
        { ien: "10", name: "CARDIOLOGY", code: "CARD" }
      ])
    end

    result = RpmsRpc::Referral.add(DFN)

    refute result[:success]
    assert_match(/not available/i, result[:error])
    assert_equal [], RpmsRpc::Referral.reference_data("PURPOSE")
    assert_nil RpmsRpc.client.received_calls.find { |c| c[:rpc].start_with?("BMC ") }
  end

  # -- BMCRPC context binding (rpms-rpc#258) ---------------------------------
  #
  # RPC registration is OPTION-scoped (RpmsRpc::ContextScope). On a built 9.0
  # image the BMC* RPCs are listed in the RPC multiple of ONE file-19 option,
  # BMCRPC (22 entries: the 21 BMC names this module calls plus ORWDXIHS
  # CLININD), and in no other — not CIAV VUECENTRIC, not OR CPRS GUI CHART.
  # So every call here, the capability probe included, must run under BMCRPC
  # and hand the caller's option back afterward, the way RpmsRpc::Agg does
  # for AGGRPC.

  # Arguments that let every public method reach the wire. Nothing is seeded:
  # the mock answers "" and still records the call with its context.
  BMC_CALLS = {
    for_patient: [ DFN ],
    find: [ "3001" ],
    delete: [ "3001" ],
    add: [ DFN, "44" ],
    add_secondary: [ "3001" ],
    update: [ "3001", "44" ],
    print: [ "3001" ],
    update_status: [ "3001", "APPROVED" ],
    update_consultation_status: [ "7", "COMPLETE" ],
    purposes: [],
    reference_data: [ "PURPOSE" ],
    users_providers: [],
    providers: [],
    search_referred_to: [ "CARD" ],
    rcis_templates: [],
    rcis_template_detail: [ "7" ],
    patient_eligibility_status: [ DFN ],
    patient_face_sheet: [ DFN ],
    patient_health_summary: [ DFN ],
    health_summary_types: [],
    check_year_site_param: [],
    add_c32_print_log: [ DFN ]
  }.freeze

  def test_the_bind_table_names_every_public_method_that_reaches_the_wire
    expected = RpmsRpc::Referral.public_instance_methods(false).sort - [ :create ]

    assert_equal expected, BMC_CALLS.keys.sort,
      "a new Referral method must be added to BMC_CALLS so its context bind is proven"
  end

  def test_every_bmc_call_runs_under_bmcrpc_and_restores_the_callers_context
    BMC_CALLS.each do |method, args|
      mock = RpmsRpc.mock!
      caller_context = mock.current_context

      RpmsRpc::Referral.public_send(method, *args)

      calls = mock.received_calls
      refute_empty calls, "#{method} made no RPC call"
      calls.each do |call|
        assert_equal "BMCRPC", call[:context],
          "#{method} sent #{call[:rpc]} under #{call[:context].inspect}; the BMC* RPCs " \
          "are registered under BMCRPC only, so it is denied there"
      end
      assert_equal caller_context, mock.current_context,
        "#{method} left the session on #{mock.current_context.inspect}"
      assert_equal [ "BMCRPC", caller_context ], mock.context_binds,
        "#{method}: expected one bind and one restore"
    end
  end

  def test_the_capability_probe_is_answered_under_bmcrpc
    # Client#supports? probes BMC GET REFERENCE DATA, which is itself in the
    # BMCRPC multiple only: probed under the caller's option it answers
    # "not here", and every BMC method would short-circuit to unsupported.
    probing = Class.new(RpmsRpc::MockClient) do
      attr_reader :probed_under

      def supports?(feature)
        @probed_under = current_context if feature == :bmc_referral_workflow
        true
      end
    end.new
    RpmsRpc.configure { |c| c.client = probing }

    RpmsRpc::Referral.reference_data("PURPOSE")

    assert_equal "BMCRPC", probing.probed_under
  end

  def test_create_binds_no_context
    mock = RpmsRpc.mock!

    RpmsRpc::Referral.create(DFN, { specialty: "CARDIOLOGY" })

    assert_empty mock.context_binds, "create touches no RPC, so it has no option to bind"
  end

  def test_a_bmcrpc_that_will_not_bind_raises_before_any_rpc_is_sent
    # The broker refusing the option (not installed, or not on the user's
    # menu tree) is a session-level failure the caller must see — a BMC call
    # sent anyway would be answered a truthful "not runnable here".
    mock = RpmsRpc.mock!
    mock.unbindable_context!("BMCRPC")

    assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Referral.purposes }
    assert_empty mock.received_calls
  end

  def test_a_client_that_cannot_scope_contexts_runs_as_is
    plain = Class.new do
      attr_reader :calls

      def initialize = @calls = []
      def supports?(*) = true

      def call_rpc(rpc, *params)
        @calls << rpc
        "1^3001"
      end
    end.new
    RpmsRpc.configure { |c| c.client = plain }

    result = RpmsRpc::Referral.add(DFN, "44")

    assert result[:success]
    assert_equal [ "BMC ADD REFERRAL" ], plain.calls
  end
end
