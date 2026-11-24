# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/patient"
require_relative "../captured_replies"

# AGG LOOKUP PATIENTS — parameter and column contract.
#
# Oracle: FOIA-RPMS `Packages/Patient Registration GUI/Routines/AGGPTLKP.m`,
# entry point FND, and the replies it sent PROFILE,REG on a throwaway
# container of the pinned build (test/fixtures/captured_replies/
# agg-patient-lookup.yml). There, ALPHA,AVERY's HRN was inactivated, the
# facility's community columns turned on, and BEACON,DREW made a sensitive
# record, all through stock FileMan.
#
#   FND(DATA,TEXT,TYPE,ALL,INAC) ; EP -- AGG LOOKUP PATIENTS   (AGGPTLKP.m:7)
#     TEXT - search text (name, SSN, HRN, ...)
#     TYPE - search type code; "" searches all cross-references
#     ALL  - blank: search the user's division; 1: search all divisions
#     INAC - blank: exclude inactive patients; 1: include inactive patients
#
# This is the IHS division-aware lookup. Stock `ORWPT LIST ALL` (mapping
# :patient_list, used by Patient.search) has no division screen and no
# active/inactive concept, so on a multi-divisional RPMS it returns patients
# from every division to a user scoped to one — see lakeraven-ehr#388.
#
# MIS-READ THIS PINS: the caller's THIRD parameter is ALL (all-divisions);
# INAC is the FOURTH. AGGPTLKP has no result-limit parameter at all, so a
# limit passed positionally does not truncate anything — it silently turns on
# all-divisions or inactive search.
class AggPatientLookupTest < Minitest::Test
  SLUG = "agg-patient-lookup"

  def teardown
    RpmsRpc.reset!
  end

  def replay(flow = nil)
    @client = CapturedReplies::ReplayCiaClient.new(flow ? CapturedReplies.flow_script(SLUG, flow) : {})
    RpmsRpc.configure { |cfg| cfg.client = @client }
  end

  def sent = @client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params] ] }
  def recorded(flow) = CapturedReplies.flow_calls(SLUG, flow)
  def names(rows) = rows.map { |r| r[:name] }

  # -- Parameter contract ----------------------------------------------------

  def test_defaults_scope_to_the_users_division_and_exclude_inactive
    replay("by_name")

    rows = RpmsRpc::Patient.lookup("ALPHA")

    assert_equal [ [ "AGG LOOKUP PATIENTS", [ "ALPHA", "", "", "" ] ] ], sent,
                 'TYPE="" searches every cross-reference (AGGPTLKP.m:60); blank ALL and INAC (AGGPTLKP.m:13, :66)'
    assert_equal recorded("by_name"), sent
    assert_equal [ "ALPHA,CASEY" ], names(rows), "ALPHA,AVERY's HRN is inactive, so blank INAC leaves it out"
  end

  def test_sends_text_and_type_in_the_declared_order
    replay("by_name_type_n")

    RpmsRpc::Patient.lookup("ALPHA", type: "N")

    assert_equal recorded("by_name_type_n"), sent
  end

  def test_all_divisions_is_the_third_parameter
    replay("all_divisions")

    rows = RpmsRpc::Patient.lookup("ALPHA", all_divisions: true)

    assert_equal [ "ALPHA", "", "1", "" ], sent.first.last, "ALL is FND's 4th formal / the caller's 3rd parameter"
    assert_equal recorded("all_divisions"), sent
    assert_equal [ "*990051-DIC", "990001-DIC" ], rows.map { |r| r[:hrn] }, "ALL=1 reads each HRN with its facility"
  end

  def test_include_inactive_is_the_fourth_parameter
    replay("include_inactive")

    rows = RpmsRpc::Patient.lookup("ALPHA", include_inactive: true)

    assert_equal [ "ALPHA", "", "", "1" ], sent.first.last, "INAC is FND's 5th formal / the caller's 4th parameter"
    assert_equal [ [ "ALPHA,AVERY", true ], [ "ALPHA,CASEY", false ] ], rows.map { |r| [ r[:name], r[:inactive] ] }
  end

  def test_the_two_flags_are_independent
    replay("both_flags")

    RpmsRpc::Patient.lookup("ALPHA", all_divisions: true, include_inactive: true)

    assert_equal [ "ALPHA", "", "1", "1" ], sent.first.last
  end

  def test_a_result_limit_is_refused_rather_than_sent_positionally
    replay
    error = assert_raises(ArgumentError) { RpmsRpc::Patient.lookup("ALPHA", limit: 25) }

    assert_match(/no result-limit parameter/i, error.message)
    assert_empty sent
  end

  def test_blank_search_text_is_refused_before_dispatch
    replay
    assert_raises(ArgumentError) { RpmsRpc::Patient.lookup("   ") }
    assert_empty sent
  end

  # -- "LAST, FIRST" is normalised by the server, not the client (#199) ----
  #
  # FND^AGGPTLKP strips doubled spaces and turns ", " into "," before it
  # searches (AGGPTLKP.m:53-56), then upper-cases the text (AGGPTLKP.m:61)
  # and matches a prefix. So the client sends the text as typed, in one call,
  # and never retries with the last name alone: a retry would widen a miss
  # into every patient sharing that surname.

  def test_last_comma_space_first_is_sent_as_typed_in_one_call
    replay("last_comma_space_first")

    rows = RpmsRpc::Patient.lookup("MOUSE, MICKEY M")

    assert_equal [ "MOUSE,MICKEY M" ], names(rows)
    assert_equal [ [ "AGG LOOKUP PATIENTS", [ "MOUSE, MICKEY M", "", "", "" ] ] ], sent, "no client-side retry"
  end

  def test_an_empty_last_first_result_is_not_retried_with_the_last_name
    replay("no_match")

    assert_empty RpmsRpc::Patient.lookup("NOSUCH, PERSON")
    assert_equal recorded("no_match"), sent
  end

  # -- Column contract -------------------------------------------------------

  def test_parses_a_row_into_the_declared_columns
    replay("last_comma_space_first")

    row = RpmsRpc::Patient.lookup("MOUSE, MICKEY M").first

    assert_equal({ dfn: 3, name: "MOUSE,MICKEY M", hrn: "1001", ssn: nil, ssn_masked: true, dob: "FEB 14,1910",
                   dod: nil, sens_flag: "N", alias: nil, inactive: false },
                 row.slice(:dfn, :name, :hrn, :ssn, :ssn_masked, :dob, :dod, :sens_flag, :alias, :inactive))
  end

  def test_reads_every_row_of_a_many_row_reply
    replay("many")

    assert_equal [ 4, 990_013 ], RpmsRpc::Patient.lookup("DEMO").map { |r| r[:dfn] }
  end

  def test_header_only_response_is_an_empty_result_not_an_error
    replay("no_match")

    assert_equal [], RpmsRpc::Patient.lookup("NOSUCH, PERSON")
  end

  # AGGPTLKP.m:139 — COMM and MOMDN are appended only when the facility's
  # community-display flag is "Y" AND ALL=1. A nine-column read must not
  # break when eleven arrive.
  def test_tolerates_the_optional_trailing_community_columns
    replay("all_divisions")

    rows = RpmsRpc::Patient.lookup("ALPHA", all_divisions: true)

    assert_equal [ 990_051, 990_001 ], rows.map { |r| r[:dfn] }
    assert(rows.all? { |r| r.key?(:community) && r.key?(:mothers_maiden_name) })
  end

  # require_response checks the header and each row first; both shapes pass.
  def test_require_response_accepts_the_nine_and_the_eleven_column_reply
    replay("all_divisions")
    assert_equal 2, RpmsRpc::Patient.lookup("ALPHA", all_divisions: true, require_response: true).size

    replay("by_name")
    assert_equal 1, RpmsRpc::Patient.lookup("ALPHA", require_response: true).size
  end

  def test_the_sensitive_flag_is_read
    replay("sensitive")

    assert_equal "Y", RpmsRpc::Patient.lookup("BEACON").first[:sens_flag]
  end

  # -- SSN masking is a wire behaviour, not patient data ---------------------

  # AGGPTLKP.m:124 — without the AGZVIEWSSN security key the routine returns
  # "XXX-XX-" _ $E(SSN,6,9) in a division search. That is a redaction, not an
  # identifier, and a caller that stores it has stored a fake SSN.
  def test_masked_ssn_is_not_surfaced_as_an_ssn
    replay("by_name")

    row = RpmsRpc::Patient.lookup("ALPHA").first

    assert_nil row[:ssn]
    assert_equal true, row[:ssn_masked]
  end

  # The same line skips the mask when ALL=1, so an all-divisions search sends
  # the whole SSN to a user without AGZVIEWSSN.
  def test_unmasked_ssn_is_surfaced
    replay("all_divisions")

    row = RpmsRpc::Patient.lookup("ALPHA", all_divisions: true).last

    assert_equal "666021001", row[:ssn]
    assert_equal false, row[:ssn_masked]
  end

  def test_a_patient_with_no_ssn_has_none
    replay("no_ssn")

    row = RpmsRpc::Patient.lookup("USER,TEST").first

    assert_nil row[:ssn]
    assert_equal false, row[:ssn_masked]
  end

  # -- Wire framing: this RPC returns a GLOBAL ARRAY, not a printable string --
  #
  # FND^AGGPTLKP sets DATA=$NA(^TMP("AGGPTLK",UID)), so the broker sends a
  # return-type-4 reply: typed header, then $C(30)-separated records, ending at
  # $C(31). $C(30) IS the CIA EOD, so a plain call_rpc read stops at the header
  # and every data row is lost. CiaClient#call_rpc_global_array reads to the
  # $C(31) sentinel instead.
  def test_lookup_reads_the_global_array_and_does_not_truncate_at_the_header
    replay("many")
    @client.define_singleton_method(:call_rpc) { |*| raise "AGG LOOKUP PATIENTS must not be read with call_rpc" }

    assert_equal 2, RpmsRpc::Patient.lookup("DEMO").size
  end

  # BMX has no global-array read; the lookup falls back to call_rpc, and
  # BmxClient's own reply grammar reads the frame the build sent.
  def test_lookup_falls_back_to_call_rpc_over_bmx
    client = CapturedReplies::ReplayBmxClient.new(CapturedReplies.flow_script(SLUG, "bmx_by_name"))
    RpmsRpc.configure { |cfg| cfg.client = client }
    RpmsRpc::Authentication.authenticate(access_code: "PREG123", verify_code: "PREG123!!")

    rows = RpmsRpc::Patient.lookup("MOUSE")

    assert_equal [ "MOUSE,MICKEY M" ], names(rows)
    assert_equal CapturedReplies.flow_calls(SLUG, "bmx_by_name").map(&:first), client.rpcs_called
  end

  # AGG LOOKUP PATIENTS is in AGGRPC's RPC multiple only; a CIA session binds
  # CIAV VUECENTRIC, which refuses it. The lookup binds AGGRPC for its call.
  def test_lookup_runs_in_the_aggrpc_context
    replay("by_name")

    RpmsRpc::Patient.lookup("ALPHA")

    assert_equal [ "AGGRPC", "CIAV VUECENTRIC" ],
                 @client.calls.select { |c| c[:rpc] == :create_context }.map { |c| c[:params].first }
  end
end
