# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/patient"

class RegistrationSafetyTest < Minitest::Test
  Reg = RpmsRpc::Registration
  Agg = RpmsRpc::Agg
  ATTRS = { name: "DEMOPATIENT,UNA", dob: Date.new(1990, 1, 2), sex: "F" }.freeze
  # HDR/LST2^AGGPTLKP: name OR DOB candidates, no sex column.
  HEADER = "I00010DFN^T00030PATIENT_NAME^T00030HRN^T00009SSN^D00030DOB^D00030DOD^T00003SENS_FLAG^T01024ALIAS^T00001INACTIVE"
  ROW = "42^DEMOPATIENT,UNA^42^900010001^01/02/1990^^^^N"
  QUERY = "AGGPTLNM=DEMOPATIENT\x1cAGGPTFNM=UNA\x1cAGGPTMNM=\x1cAGGPTSFX=\x1cAGGPTDOB=01/02/1990"

  def setup
    @mock = RpmsRpc.mock!
    Reg.hrn_mode = Reg::HRN_MODE_DERIVE
    @mock.seed(:agg_add_patient, Agg::NEW_PATIENT_WINDOW, "I00010RESULT^T00080MESSAGE^I00010DFN\x1e1^^42\x1e\x1f")
    @mock.seed(:agg_update_patient, Agg::DEFAULT_WINDOW, "I00010RESULT^T01024ERROR^T01024OTHER_PARMS\x1e1^^\x1e\x1f")
  end

  def teardown
    Reg.hrn_mode = Reg::HRN_MODE_DERIVE
    RpmsRpc.reset!
  end

  def seed_lookup(rows = [], query: QUERY)
    @mock.seed_raw_lines(:patient_lookup_agg, query, [ HEADER, *rows ])
  end

  def assert_no_write
    assert_empty @mock.received_calls.reject { |c| c[:rpc] == "AGG LOOKUP PATIENTS" }
  end

  def test_second_registration_refuses_and_only_one_patient_is_added
    seed_lookup
    original = @mock.method(:call_rpc_global_array)
    @mock.define_singleton_method(:call_rpc_global_array) do |rpc, *params|
      response = original.call(rpc, *params)
      seed_raw_lines(:patient_lookup_agg, QUERY, [ HEADER, ROW ]) if rpc == "AGG ADD NEW PATIENT"
      response
    end

    assert_equal({ success: true, dfn: 42, created: true }, RpmsRpc::Patient.register(ATTRS))
    assert_equal({ success: false, error: :duplicate_identity, candidate_dfns: [ 42 ],
                   message: "matching patient candidates require explicit override" }, RpmsRpc::Patient.register(ATTRS))
    assert_equal [ "AGG LOOKUP PATIENTS", "AGG ADD NEW PATIENT", "AGG UPDATE PATIENT", "AGG LOOKUP PATIENTS" ],
                 @mock.received_calls.map { |c| c[:rpc] }
    lookup = @mock.received_calls.first
    assert_equal [ QUERY, "", "1", "1" ], lookup[:params]
    assert_equal "AGGRPC", lookup[:context]
    assert_equal "OR CPRS GUI CHART", @mock.current_context
  end

  def test_candidates_are_deduplicated_and_sorted_without_demographics
    seed_lookup([ ROW.sub("42^", "43^"), ROW, ROW ])
    assert_equal({ success: false, error: :duplicate_identity, candidate_dfns: [ 42, 43 ],
                   message: "matching patient candidates require explicit override" }, Reg.register(ATTRS))
    assert_no_write
  end

  def test_explicit_boolean_override_allows_add_but_still_looks_up
    seed_lookup([ ROW ])
    assert Reg.register(ATTRS.merge(allow_duplicate: true))[:success]
    assert_equal "AGG LOOKUP PATIENTS", @mock.received_calls.first[:rpc]
  end

  [ "true", "false", 1, nil, false ].each_with_index do |override, i|
    define_method("test_non_boolean_override_#{i}_does_not_authorize_add") do
      seed_lookup([ ROW ])
      assert_equal :duplicate_identity, Reg.register(ATTRS.merge(allow_duplicate: override))[:error]
      assert_no_write
    end
  end

  # The server searches by name OR DOB. A DOB disagreement cannot rule out
  # name resolution in ADD^AGGPTADD, and a name disagreement is for review.
  { name: ROW.sub("DEMOPATIENT,UNA", "OTHERDEMO,BOB"),
    dob: ROW.sub("1990", "1991"), missing_dob: ROW.sub("01/02/1990", ""),
    inactive: ROW.sub(/N\z/, "Y") }.each do |field, row|
    define_method("test_candidate_with_different_#{field}_still_requires_review") do
      seed_lookup([ row ])
      assert_equal({ success: false, error: :duplicate_identity, candidate_dfns: [ 42 ],
                     message: "matching patient candidates require explicit override" }, Reg.register(ATTRS))
      assert_no_write
    end
  end

  { last_name: { name: ",UNA" }, first_name: { name: "DEMOPATIENT," },
    dob: { dob: " " }, sex: { sex: " " } }.each do |field, change|
    define_method("test_missing_#{field}_refuses_with_exact_field_name") do
      assert_equal({ success: false, error: :identity_unverifiable,
                     message: "patient identity missing or invalid: #{field}" }, Reg.register(ATTRS.merge(change)))
      assert_empty @mock.received_calls
    end
  end

  [ "2/30/1990", "1/2/90garbage", "TODAY" ].each_with_index do |date, i|
    define_method("test_invalid_dob_#{i}_refuses") do
      assert_equal({ success: false, error: :identity_unverifiable,
                     message: "patient identity missing or invalid: dob" }, Reg.register(ATTRS.merge(dob: date)))
      assert_empty @mock.received_calls
    end
  end

  [ "1/2/90", " 1/2/1990 ", "1990-01-02", "2900102", "JAN 02, 1990" ].each_with_index do |dob, i|
    define_method("test_equivalent_dob_#{i}_uses_the_same_lookup_and_add_date") do
      seed_lookup
      assert Reg.register(ATTRS.merge(dob: dob))[:success]
      assert_equal QUERY, @mock.received_calls.first[:params].first
      add = @mock.received_calls.find { |c| c[:rpc] == "AGG ADD NEW PATIENT" }
      assert_includes add[:params][2].split("\x1c"), "AGGPTDOB=01/02/1990"
    end
  end

  def test_name_pieces_used_for_both_lookup_and_add
    query = QUERY.sub("AGGPTMNM=", "AGGPTMNM=MAE").sub("AGGPTSFX=", "AGGPTSFX=JR")
    seed_lookup(query: query)
    attrs = ATTRS.merge(name: nil, name_last: " demopatient ", name_first: " una ", name_middle: "MAE", name_suffix: "JR")
    assert Reg.register(attrs)[:success]
    assert_equal query, @mock.received_calls.first[:params].first
  end

  [ nil, "", "M ERROR DEMOPATIENT,UNA", HEADER.split("^").first,
    [ HEADER, ROW.sub("42^", "0^") ], [ HEADER, ROW.sub("42^", "42oops^") ],
    [ HEADER, "42^DEMOPATIENT,UNA" ], [ HEADER, HEADER ] ].each_with_index do |reply, i|
    define_method("test_unverified_lookup_#{i}_refuses_even_with_override") do
      @mock.seed_raw_lines(:patient_lookup_agg, QUERY, Array(reply))
      assert_equal({ success: false, error: :identity_unverifiable,
                     message: "patient duplicate lookup could not be verified" }, Reg.register(ATTRS.merge(allow_duplicate: true)))
      assert_no_write
    end
  end

  [ RpmsRpc::Client::RpcError, RpmsRpc::Client::ConnectionError ].each_with_index do |error, i|
    define_method("test_failed_lookup_#{i}_refuses_without_echoing_error") do
      @mock.define_singleton_method(:call_rpc_global_array) { |*| raise error, "DEMOPATIENT,UNA 900010001" }
      assert_equal({ success: false, error: :identity_unverifiable,
                     message: "patient duplicate lookup could not be verified" }, Reg.register(ATTRS))
      assert_no_write
    end
  end

  def test_context_failure_never_falls_back_to_another_write_path
    @mock.unbindable_context!("AGGRPC")
    assert_equal :identity_unverifiable, Reg.register(ATTRS)[:error]
    assert_empty @mock.received_calls
  end

  [ "", "\r", "\n", "\r\n" ].each_with_index do |feed, i|
    define_method("test_global_array_framing_#{i}_preserves_candidates") do
      @mock.seed_raw_lines(:patient_lookup_agg, QUERY, [ "7\x00#{HEADER}\x1e#{feed}#{ROW}\x1e#{feed}\x1f" ])
      assert_equal :duplicate_identity, Reg.register(ATTRS)[:error]
      assert_no_write
    end
  end

  def test_parameter_delimiter_cannot_change_identity_after_lookup
    assert_raises(ArgumentError) { Reg.register(ATTRS.merge(tribe: "123\x1cAGGPTLNM=OTHERDEMO")) }
    assert_empty @mock.received_calls
  end

end
