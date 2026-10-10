# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/registration"

# #407: synthetic identities only. Single-field failures assert the entire
# result and the absence of any lock/filer call, so a hardcoded field list
# cannot masquerade as a correct divergence check.
class RegistrationIdentityTest < Minitest::Test
  Reg = RpmsRpc::Registration
  Ddr = RpmsRpc::DdrFileman
  ATTRS = { name: "DEMOPATIENT,UNA", dob: Date.new(1990, 1, 2), sex: "F",
            ssn: "900010001", station_number: "8994", full_icn: "1000000001V123456",
            type: "NON-VETERAN (OTHER)", veteran: "N", service_connected: "N" }.freeze
  HEADER = "I00010DFN^T00030PATIENT_NAME^T00030HRN^T00009SSN^D00030DOB"

  def setup
    @mock = RpmsRpc.mock!
    Reg.hrn_mode = Reg::HRN_MODE_DERIVE
    @mock.seed_scalar(:agg_canrun, "AGG ADD NEW PATIENT", "0")
  end

  def teardown
    Reg.hrn_mode = Reg::HRN_MODE_DERIVE
    RpmsRpc.reset!
  end

  def seed_composition(attrs = ATTRS, chart: ATTRS, dfn: "42", lock: true)
    @mock.seed(:voa_add_patient, Reg.voa_param(attrs).to_s, { status: 1, dfn_or_error: dfn })
    @mock.seed(:patient_id_info, dfn, chart) if chart
    @mock.seed(:ddr_lock_unlock_node, Ddr.lock_param(node: "^AUPNPAT(#{dfn})").to_s, lock) unless lock.nil?
    # Existing IHS half, no completion attrs: a successful verification does
    # take the lock but needs no filing.
    @mock.seed(:ddr_gets_entry_data,
      Ddr.gets_entry_param(file: "9000001", iens: "#{dfn},", fields: ".01").to_s,
      "[Data]\n9000001^#{dfn}^.01^#{dfn}^DEMOPATIENT,UNA")
  end

  def assert_no_completion
    assert_empty @mock.received_calls.select { |call| call[:rpc].start_with?("DDR ") }
  end

  { last_name: { name: "OTHERDEMO,UNA" }, first_name: { name: "DEMOPATIENT,BOB" },
    dob: { dob: Date.new(1991, 1, 2) }, sex: { sex: "M" }, ssn: { ssn: "900010002" } }.each do |field, change|
    define_method("test_composition_refuses_only_diverging_#{field}") do
      seed_composition(chart: ATTRS.merge(change))
      assert_equal({ success: false, error: :identity_mismatch,
                     message: "patient identity differs: #{field}" }, Reg.register(ATTRS))
      assert_no_completion
    end
  end

  { last_name: { name: ",UNA" }, dob: { dob: " " }, sex: { sex: " " } }.each do |field, change|
    define_method("test_blank_request_#{field}_refuses_before_voa") do
      assert_equal({ success: false, error: :identity_unverifiable,
                     message: "patient identity missing or invalid: #{field}" }, Reg.register(ATTRS.merge(change)))
      assert_no_completion
      refute @mock.received_calls.any? { |call| call[:rpc] == "VAFC VOA ADD PATIENT" }
    end

    define_method("test_blank_chart_#{field}_refuses") do
      seed_composition(chart: ATTRS.merge(change))
      assert_equal({ success: false, error: :identity_unverifiable,
                     message: "patient identity missing or invalid: #{field}" }, Reg.register(ATTRS))
      assert_no_completion
    end
  end

  def test_unreadable_chart_refuses
    seed_composition(chart: nil)
    assert_equal({ success: false, error: :identity_unverifiable,
                   message: "patient identity could not be verified" }, Reg.register(ATTRS))
    assert_no_completion
  end

  def test_rpc_error_reading_chart_refuses_without_echoing_the_error
    seed_composition
    @mock.define_singleton_method(:call_rpc) do |rpc, *params|
      raise RpmsRpc::Client::RpcError, "DEMOPATIENT,UNA 900010001 01/02/1990" if rpc == "ORWPT ID INFO"
      super(rpc, *params)
    end
    assert_equal({ success: false, error: :identity_unverifiable,
                   message: "patient identity could not be verified" }, Reg.register(ATTRS))
    assert_no_completion
  end

  def test_identical_chart_is_verified_before_locking
    seed_composition
    assert Reg.register(ATTRS)[:success]
    rpcs = @mock.received_calls.map { |call| call[:rpc] }
    assert_operator rpcs.index("ORWPT ID INFO"), :<, rpcs.index("DDR LOCK/UNLOCK NODE")
  end

  [ "1/2/90", " 1/2/1990 ", "1990-01-02", "2900102", "JAN 02, 1990" ].each_with_index do |dob, i|
    define_method("test_equivalent_dob_format_#{i}") do
      attrs = ATTRS.merge(dob: dob)
      seed_composition(attrs)
      assert Reg.register(attrs)[:success]
    end
  end

  def test_name_pieces_and_normalization_match_chart
    attrs = ATTRS.merge(name: nil, name_last: " demopatient ", name_first: " una ", name_middle: "MAE",
                        name_suffix: "JR", sex: "female", ssn: "900-01-0001")
    seed_composition(attrs, chart: ATTRS.merge(name: "DEMOPATIENT,UNA MAE JR"))
    assert Reg.register(attrs)[:success]
  end

  def test_optional_ssn_absent_on_request_does_not_compare_pseudo_ssn
    attrs = ATTRS.merge(ssn: nil)
    seed_composition(attrs)
    assert Reg.register(attrs)[:success]
  end

  def test_ssn_given_on_request_but_absent_on_chart_refuses
    seed_composition(chart: ATTRS.merge(ssn: nil))
    assert_equal({ success: false, error: :identity_mismatch,
                   message: "patient identity differs: ssn" }, Reg.register(ATTRS))
    assert_no_completion
  end

  def test_invalid_voa_dfn_refuses
    seed_composition(dfn: "42oops")
    assert_equal :identity_unverifiable, Reg.register(ATTRS)[:error]
    assert_no_completion
  end

  def test_silent_registration_lock_returns_nil_without_filing_or_unlocking
    seed_composition(lock: nil)
    assert_nil Reg.register(ATTRS)
    assert_equal [ "DDR LOCK/UNLOCK NODE" ], @mock.received_calls.filter_map { |c| c[:rpc] if c[:rpc].start_with?("DDR ") }
  end

  def test_refused_registration_lock_returns_lock_failed
    seed_composition(lock: false)
    assert_equal :lock_failed, Reg.register(ATTRS)[:error]
    assert_equal [ "DDR LOCK/UNLOCK NODE" ], @mock.received_calls.filter_map { |c| c[:rpc] if c[:rpc].start_with?("DDR ") }
  end

  def test_silent_update_lock_preserves_retryable_contract
    assert_equal :lock_failed, Reg.update(42, patient_fields: { ".111" => "EXAMPLE" })[:error]
    refute @mock.received_calls.any? { |call| call[:rpc] == "DDR FILER" }
  end

  def test_availability_error_does_not_fall_back
    @mock.unbindable_context!("AGGRPC")
    seed_composition
    assert_raises(RpmsRpc::Client::RpcError) { Reg.register(ATTRS) }
    assert_empty @mock.received_calls
  end

  def test_availability_silence_does_not_fall_back
    @mock.seed_scalar(:agg_canrun, "AGG ADD NEW PATIENT", "")
    assert_nil Reg.register(ATTRS)
    assert_equal [ "CIANBRPC CANRUN" ], @mock.received_calls.map { |call| call[:rpc] }
  end

  def seed_ag(rows: [])
    @mock.seed_scalar(:agg_canrun, "AGG ADD NEW PATIENT", "1")
    @mock.seed_raw_lines(:patient_lookup_agg, "DEMOPATIENT,UNA", [ HEADER, *rows ])
    @mock.seed(:agg_add_patient, RpmsRpc::Agg::NEW_PATIENT_WINDOW,
      "I00010RESULT^T00080MESSAGE^I00010DFN\x1e1^^42\x1e\x1f")
    @mock.seed(:agg_update_patient, RpmsRpc::Agg::DEFAULT_WINDOW,
      "I00010RESULT^T01024ERROR^T01024OTHER_PARMS\x1e1^^\x1e\x1f")
  end

  def matching_row(dfn = 42)
    "#{dfn}^DEMOPATIENT,UNA^42^900010001^01/02/1990"
  end

  def assert_no_ag_write
    refute @mock.received_calls.any? { |call| [ "AGG ADD NEW PATIENT", "AGG UPDATE PATIENT", "DDR FILER" ].include?(call[:rpc]) }
  end

  def test_duplicate_returns_all_candidate_dfns_and_no_phi
    seed_ag(rows: [ matching_row(43), matching_row(42), matching_row(43) ])
    assert_equal({ success: false, error: :duplicate_identity, candidate_dfns: [ 42, 43 ],
                   message: "matching patient candidates require explicit override" }, Reg.register(ATTRS))
    assert_no_ag_write
    lookup = @mock.received_calls.find { |call| call[:rpc] == "AGG LOOKUP PATIENTS" }
    assert_equal [ "DEMOPATIENT,UNA", "N", "1", "1" ], lookup[:params]
    assert_equal "AGGRPC", lookup[:context]
    assert_equal "OR CPRS GUI CHART", @mock.current_context
  end

  def test_two_registrations_create_only_one_patient
    seed_ag
    original = @mock.method(:call_rpc_global_array)
    @mock.define_singleton_method(:call_rpc_global_array) do |rpc, *params|
      reply = original.call(rpc, *params)
      if rpc == "AGG ADD NEW PATIENT"
        seed_raw_lines(:patient_lookup_agg, "DEMOPATIENT,UNA",
          [ HEADER, "42^DEMOPATIENT,UNA^42^900010001^01/02/1990" ])
      end
      reply
    end
    assert Reg.register(ATTRS)[:success]
    assert_equal :duplicate_identity, Reg.register(ATTRS)[:error]
    assert_equal 1, @mock.received_calls.count { |call| call[:rpc] == "AGG ADD NEW PATIENT" }
  end

  def test_explicit_duplicate_override_allows_add
    seed_ag(rows: [ matching_row ])
    assert Reg.register(ATTRS.merge(allow_duplicate: true))[:success]
  end

  def test_string_override_does_not_allow_add
    seed_ag(rows: [ matching_row ])
    assert_equal :duplicate_identity, Reg.register(ATTRS.merge(allow_duplicate: "true"))[:error]
    assert_no_ag_write
  end

  def test_same_name_different_dob_does_not_block_add
    seed_ag(rows: [ matching_row.sub("1990", "1991") ])
    assert Reg.register(ATTRS)[:success]
  end

  def test_name_prefix_candidate_is_not_an_exact_match
    seed_ag(rows: [ matching_row.sub("UNA", "UNABELLE") ])
    assert Reg.register(ATTRS)[:success]
  end

  def test_candidate_with_unreadable_dob_requires_override
    seed_ag(rows: [ matching_row.sub("01/02/1990", "") ])
    assert_equal :duplicate_identity, Reg.register(ATTRS)[:error]
    assert_no_ag_write
  end

  def test_lookup_silence_is_not_an_empty_result_even_with_override
    @mock.seed_scalar(:agg_canrun, "AGG ADD NEW PATIENT", "1")
    assert_equal({ success: false, error: :identity_unverifiable,
                   message: "patient duplicate lookup could not be verified" }, Reg.register(ATTRS.merge(allow_duplicate: true)))
    assert_no_ag_write
  end

  def test_malformed_lookup_is_not_an_empty_result
    seed_ag(rows: [ "M ERROR WITH DEMOPATIENT DATA" ])
    assert_equal({ success: false, error: :identity_unverifiable,
                   message: "patient duplicate lookup could not be verified" }, Reg.register(ATTRS))
    assert_no_ag_write
  end
  def test_compound_first_name_divergence_is_not_hidden_by_first_token
    attrs = ATTRS.merge(name: "DEMOPATIENT,UNA MAE")
    seed_composition(attrs, chart: attrs.merge(name: "DEMOPATIENT,UNA LEE"))
    assert_equal({ success: false, error: :identity_mismatch,
                   message: "patient identity differs: first_name" }, Reg.register(attrs))
    assert_no_completion
  end

  def test_blank_name_and_invalid_dob_cannot_bypass_verification
    [ { name: " " }, { name_last: "", name_first: "UNA" }, { dob: "2/30/1990" } ].each do |change|
      assert_equal :identity_unverifiable, Reg.register(ATTRS.merge(change))[:error]
    end
    assert_no_completion
  end

  def test_ag_blank_identity_refuses_before_lookup_or_add
    seed_ag
    assert_equal :identity_unverifiable, Reg.register(ATTRS.merge(name: ",UNA", allow_duplicate: true))[:error]
    assert_no_ag_write
    refute @mock.received_calls.any? { |call| call[:rpc] == "AGG LOOKUP PATIENTS" }
  end

  def test_availability_connection_error_does_not_fall_back
    @mock.define_singleton_method(:call_rpc_lines) do |*|
      raise RpmsRpc::Client::ConnectionError, "unreachable"
    end
    assert_raises(RpmsRpc::Client::ConnectionError) { Reg.register(ATTRS) }
    assert_empty @mock.received_calls
  end

  def test_malformed_availability_reply_does_not_fall_back
    @mock.seed_scalar(:agg_canrun, "AGG ADD NEW PATIENT", "INVALID")
    assert_raises(RpmsRpc::Client::RpcError) { Reg.register(ATTRS) }
    assert_equal [ "CIANBRPC CANRUN" ], @mock.received_calls.map { |call| call[:rpc] }
  end

  def test_lookup_zero_dfn_is_not_a_candidate_to_ignore
    seed_ag(rows: [ matching_row(0) ])
    assert_equal :identity_unverifiable, Reg.register(ATTRS)[:error]
    assert_no_ag_write
  end

  def test_truncated_header_is_not_an_empty_result
    seed_ag
    @mock.seed_raw_lines(:patient_lookup_agg, "DEMOPATIENT,UNA", [ "I00010DFN^T00030PATIENT_NAME^" ])
    assert_equal :identity_unverifiable, Reg.register(ATTRS)[:error]
    assert_no_ag_write
  end

  [ "", "\r", "\n", "\r\n" ].each_with_index do |feed, i|
    define_method("test_framed_lookup_candidates_refuse_with_line_ending_#{i}") do
      seed_ag
      wire = "7\x00#{HEADER}\x1e#{feed}#{matching_row}\x1e#{feed}\x1f"
      @mock.seed_raw_lines(:patient_lookup_agg, "DEMOPATIENT,UNA", [ wire ])
      assert_equal :duplicate_identity, Reg.register(ATTRS)[:error]
      assert_no_ag_write
    end
  end
end
