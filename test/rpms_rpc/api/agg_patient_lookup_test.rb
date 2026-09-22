# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/mappings"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/patient"

# AGG LOOKUP PATIENTS — parameter and column contract.
#
# Oracle: FOIA-RPMS `Packages/Patient Registration GUI/Routines/AGGPTLKP.m`,
# entry point FND. Every assertion cites the M it pins.
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
  # AGGPTLKP.m:174 — the typed column header this RPC opens with.
  HEADER = "I00010DFN^T00030PATIENT_NAME^T00030HRN^T00009SSN^" \
           "D00030DOB^D00030DOD^T00003SENS_FLAG^T01024ALIAS^T00001INACTIVE"

  def setup
    RpmsRpc.mock!
  end

  # -- Parameter contract ----------------------------------------------------

  def test_sends_text_and_type_in_the_declared_order
    RpmsRpc::Patient.lookup("ANDERSON", type: "N")

    assert_equal "AGG LOOKUP PATIENTS", last_call[:rpc]
    assert_equal "ANDERSON", last_call[:params][0]
    assert_equal "N",        last_call[:params][1]
  end

  def test_all_divisions_is_the_third_parameter
    RpmsRpc::Patient.lookup("ANDERSON", all_divisions: true)

    assert_equal "1", last_call[:params][2],
                 "ALL is FND's 4th formal / the caller's 3rd parameter (AGGPTLKP.m:7)"
  end

  def test_include_inactive_is_the_fourth_parameter
    RpmsRpc::Patient.lookup("ANDERSON", include_inactive: true)

    assert_equal "1", last_call[:params][3],
                 "INAC is FND's 5th formal / the caller's 4th parameter (AGGPTLKP.m:7)"
  end

  def test_defaults_scope_to_the_users_division_and_exclude_inactive
    RpmsRpc::Patient.lookup("ANDERSON")

    assert_equal "", last_call[:params][2],
                 "blank ALL applies the division screen (AGGPTLKP.m:66)"
    assert_equal "", last_call[:params][3],
                 "blank INAC excludes inactive patients (AGGPTLKP.m:13)"
  end

  def test_blank_type_searches_all_cross_references
    RpmsRpc::Patient.lookup("ANDERSON")

    assert_equal "", last_call[:params][1],
                 'TYPE="" falls through to the all-cross-reference lookup (AGGPTLKP.m:60)'
  end

  def test_the_two_flags_are_independent
    RpmsRpc::Patient.lookup("ANDERSON", all_divisions: true, include_inactive: true)

    assert_equal %w[1 1], last_call[:params][2, 2]
  end

  def test_a_result_limit_is_refused_rather_than_sent_positionally
    error = assert_raises(ArgumentError) do
      RpmsRpc::Patient.lookup("ANDERSON", limit: 25)
    end

    assert_match(/no result-limit parameter/i, error.message)
  end

  def test_blank_search_text_is_refused_before_dispatch
    assert_raises(ArgumentError) { RpmsRpc::Patient.lookup("   ") }
    assert_empty RpmsRpc.client.received_calls
  end

  # -- Column contract -------------------------------------------------------

  def test_parses_a_row_into_the_declared_columns
    seed([ HEADER, "3^ANDERSON,ALICE^104827^000009999^05/15/1980^^^^N", "" ])

    result = RpmsRpc::Patient.lookup("ANDERSON").first

    assert_equal 3, result[:dfn]
    assert_equal "ANDERSON,ALICE", result[:name]
    assert_equal "104827", result[:hrn]
    assert_equal "05/15/1980", result[:dob]
    assert_equal false, result[:inactive]
  end

  def test_header_only_response_is_an_empty_result_not_an_error
    seed([ HEADER, "" ])

    assert_equal [], RpmsRpc::Patient.lookup("NOSUCHNAME")
  end

  def test_tolerates_the_optional_trailing_community_columns
    # AGGPTLKP.m:175 — COMM and MOMDN are appended only when the facility's
    # community-display flag is "Y" AND ALL=1. A nine-column read must not
    # break when eleven arrive.
    seed([ HEADER + "^T00030COMM^T00030MOMDN",
          "3^ANDERSON,ALICE^104827^000009999^05/15/1980^^^^N^EXAMPLE COMMUNITY^MAIDEN,NAME",
          "" ])

    result = RpmsRpc::Patient.lookup("ANDERSON", all_divisions: true).first

    assert_equal 3, result[:dfn]
    assert_equal "EXAMPLE COMMUNITY", result[:community]
  end

  def test_inactive_flag_is_parsed_as_a_boolean
    seed([ HEADER, "3^ANDERSON,ALICE^104827*^000009999^05/15/1980^^^^Y", "" ])

    result = RpmsRpc::Patient.lookup("ANDERSON", include_inactive: true).first

    assert_equal true, result[:inactive]
  end

  # -- SSN masking is a wire behaviour, not patient data ---------------------

  def test_masked_ssn_is_not_surfaced_as_an_ssn
    # AGGPTLKP.m:124 — without the AGZVIEWSSN security key the routine returns
    # "XXX-XX-" _ $E(SSN,6,9). That is a redaction, not an identifier, and a
    # caller that stores it has stored a fake SSN.
    seed([ HEADER, "3^ANDERSON,ALICE^104827^XXX-XX-9999^05/15/1980^^^^N", "" ])

    result = RpmsRpc::Patient.lookup("ANDERSON").first

    assert_nil result[:ssn]
    assert_equal true, result[:ssn_masked]
  end

  def test_empty_ssn_masked_to_a_bare_prefix_is_treated_as_absent
    # AGGPTLKP.m:194 (LST2) omits the SSN'="" guard that LST:124 applies, so a
    # patient with no SSN comes back as the literal "XXX-XX-" with no digits.
    seed([ HEADER, "3^ANDERSON,ALICE^104827^XXX-XX-^05/15/1980^^^^N", "" ])

    result = RpmsRpc::Patient.lookup("ANDERSON").first

    assert_nil result[:ssn]
    assert_equal true, result[:ssn_masked]
  end

  def test_unmasked_ssn_is_surfaced
    seed([ HEADER, "3^ANDERSON,ALICE^104827^000009999^05/15/1980^^^^N", "" ])

    result = RpmsRpc::Patient.lookup("ANDERSON").first

    assert_equal "000009999", result[:ssn]
    assert_equal false, result[:ssn_masked]
  end

  # -- Errors arriving as rows ----------------------------------------------

  def test_an_m_error_arriving_as_a_row_is_not_parsed_as_a_patient
    seed([ HEADER, "%YDB-E-NULSUBSC, Null subscript", "" ])

    assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Patient.lookup("ANDERSON") }
  end

  def test_a_row_whose_dfn_is_not_numeric_is_rejected
    seed([ HEADER, "M ERROR^ANDERSON,ALICE^^^^^^^N", "" ])

    assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Patient.lookup("ANDERSON") }
  end

  # -- Wire framing: this RPC returns a GLOBAL ARRAY, not a printable string --
  #
  # FND^AGGPTLKP sets DATA=$NA(^TMP("AGGPTLK",UID)) — a global reference, so
  # the broker sends a return-type-4 reply: typed header, then $C(30)-separated
  # records, ending at $C(31). $C(30) IS the CIA EOD, so a plain call_rpc read
  # stops at the header and every data row is lost on the wire while seeded
  # tests still pass. CiaClient#call_rpc_global_array reads to the $C(31)
  # sentinel instead; RpmsRpc::Agg already routes its AGG RPCs that way.
  class GlobalArrayClient
    RS = "\x1e"
    US = "\x1f"

    attr_reader :calls

    def initialize(rows)
      @rows = rows
      @calls = []
    end

    # What the socket really yields: read_until_raw(EOD) stops at the first
    # $C(30), so the caller sees the header and nothing else.
    def call_rpc(rpc_name, *params)
      @calls << [ :call_rpc, rpc_name, params ]
      full_reply.split(RS, 2).first
    end

    def call_rpc_global_array(rpc_name, *params)
      @calls << [ :call_rpc_global_array, rpc_name, params ]
      full_reply
    end

    private

    def full_reply = ([ HEADER ] + @rows).join(RS) + US
  end

  def test_lookup_reads_the_global_array_and_does_not_truncate_at_the_header
    client = GlobalArrayClient.new([ "3^ANDERSON,ALICE^104827^000009999^05/15/1980^^^^N" ])
    RpmsRpc.configure { |c| c.client = client }

    rows = RpmsRpc::Patient.lookup("ANDERSON")

    assert_equal [ :call_rpc_global_array ], client.calls.map(&:first),
      "AGG LOOKUP PATIENTS is a global-array reply; a plain call_rpc read terminates at the $C(30) header"
    assert_equal 1, rows.size, "the data row was lost — the reply was truncated at the header"
    assert_equal "ANDERSON,ALICE", rows.first[:name]
  end

  def test_a_non_utf8_patient_name_does_not_raise_on_decode
    # The wire is binary and AGGPTLKP does not promise UTF-8: a Latin-1 name
    # ("MARIA" with accented bytes) arrives as raw bytes. Labelling those rows
    # UTF-8 makes them INVALID UTF-8, and parse_many's separator regex then
    # raises "invalid byte sequence in UTF-8" on a real lookup while every
    # ASCII-only test stays green. Rows keep the reply's own encoding.
    latin1_row = "3^O\xE9,MAR\xEDA^104827^000009999^05/15/1980^^^^N".b
    payload = ("5\x00" + HEADER + "\x1e" + latin1_row + "\x1e").b

    client = Object.new
    client.define_singleton_method(:call_rpc_global_array) { |*| payload }
    RpmsRpc.configure { |c| c.client = client }

    rows = RpmsRpc::Patient.lookup("O")

    assert_equal 1, rows.size
    assert_equal 3, rows.first[:dfn]
  end

  def test_lookup_falls_back_to_call_rpc_when_the_client_has_no_global_array_read
    plain = Class.new do
      attr_reader :calls
      def initialize = @calls = []
      def call_rpc(rpc_name, *params)
        @calls << rpc_name
        [ HEADER, "3^ANDERSON,ALICE^104827^000009999^05/15/1980^^^^N" ].join("\n")
      end
    end.new
    RpmsRpc.configure { |c| c.client = plain }

    rows = RpmsRpc::Patient.lookup("ANDERSON")

    assert_equal [ "AGG LOOKUP PATIENTS" ], plain.calls
    assert_equal "ANDERSON,ALICE", rows.first[:name]
  end

  private

  def seed(lines)
    RpmsRpc.client.seed_raw_lines(:patient_lookup_agg, "ANDERSON", lines)
    RpmsRpc.client.seed_raw_lines(:patient_lookup_agg, "NOSUCHNAME", lines)
  end

  def last_call
    RpmsRpc.client.received_calls.last
  end
end
