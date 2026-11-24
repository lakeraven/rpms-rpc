# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"

# PatientSelection.find picks VueCentric's lookup from what was typed, then
# reads each patient's identifiers with BEHOPTCX PTINFO. The lookup replies are
# as rpms-ydb 7c3119b answered PROFILE,MD (live 2026-10-31); the PTINFO replies
# as bcer-9.0-20261124-60d39b6-ydb answered PROFILE,MD (live 2026-11-24).
class PatientSelectionTest < Minitest::Test
  REPLIES = {
    "BEHOPTPL LISTALL" => [ "3^MOUSE,MICKEY M", "990038^NIGHTSHADE,FINLEY", "2^USER,TEST" ],
    "BEHOPTPL HRNLKP" => [ "990001^ALPHA,AVERY^9999   1/1/1980", "3^MOUSE,MICKEY M^9999   2/14/1910" ],
    "BEHOPTPL LOOKUP" => [ "3^MOUSE,MICKEY M^XXX-XX-XXXX   2/14/1910" ],
    "BEHOPTPL DOBLKP" => [ "3^MOUSE,MICKEY M^1001   2/14/1910" ]
  }.freeze
  PTINFO = {
    "3" => [ "MOUSE,MICKEY M^M^2100214^XXX-XX-XXXX^^^^0^0^^1001^0^^^0^0^^^^" ],
    "990038" => [ "NIGHTSHADE,FINLEY^M^2590305^XXX-XX-XXXX^^^^0^0^^990038^0^^^0^0^^^^" ],
    "2" => [ "USER,TEST^M^2850505^XXX-XX-XXXX^^^^0^0^^123456^0^^^0^0^^^^" ],
    "990001" => [ "ALPHA,CASEY^F^2520526^XXX-XX-XXXX^^^^0^0^^990001^0^^^0^0^^^^" ],
    "999999" => [] # a DFN PTINFO does not find
  }.freeze

  class Recorder
    attr_reader :calls

    def initialize = @calls = []

    def call_rpc(rpc, *params)
      return PTINFO.fetch(params.first) if rpc == "BEHOPTCX PTINFO"

      @calls << [ rpc, params ]
      REPLIES.fetch(rpc)
    end
  end

  # Records PTINFO's calls too.
  class PtinfoRecorder < Recorder
    def call_rpc(rpc, *params)
      @calls << [ rpc, params ] if rpc == "BEHOPTCX PTINFO"
      super
    end
  end

  def setup
    @client = Recorder.new
    RpmsRpc.configure { |c| c.client = @client }
  end

  def teardown = RpmsRpc.reset!

  def find(text) = RpmsRpc::PatientSelection.find(text)

  def test_a_name_pages_the_index_from_just_before_it_and_keeps_names_that_begin_with_it
    assert_equal [ 3 ], find("mouse").map { |row| row[:dfn] }
    assert_equal [ [ "BEHOPTPL LISTALL", [ "MOUSD~", "1", "44" ] ] ], @client.calls
  end

  def test_four_digits_are_the_last_four_and_an_hrn_one_row_per_patient
    assert_equal [ 3, 990001 ], find("9999").map { |row| row[:dfn] }
    assert_equal [ [ "BEHOPTPL LOOKUP", [ "9999" ] ], [ "BEHOPTPL HRNLKP", [ "9999" ] ] ], @client.calls
  end

  def test_an_initial_and_last_four_or_a_full_ssn_is_the_ssn_lookup
    find("M9999")
    find("000-00-9999")
    assert_equal [ [ "BEHOPTPL LOOKUP", [ "M9999" ] ], [ "BEHOPTPL LOOKUP", [ "000-00-9999" ] ] ], @client.calls
  end

  def test_other_digits_are_a_health_record_number
    find("10012")
    assert_equal [ [ "BEHOPTPL HRNLKP", [ "10012" ] ] ], @client.calls
  end

  def test_a_date_as_typed_or_iso_is_a_date_of_birth
    find("02/14/1910")
    find("1910-02-14")
    assert_equal [ [ "BEHOPTPL DOBLKP", [ "B2/14/1910" ] ], [ "BEHOPTPL DOBLKP", [ "B2/14/1910" ] ] ], @client.calls
  end

  # S-CHT-01.1: each row carries the date of birth, sex and HRN PTINFO gives,
  # and never the SSN PTINFO masks.
  def test_each_row_carries_ptinfos_date_of_birth_sex_and_hrn
    assert_equal [ { dfn: 3, name: "MOUSE,MICKEY M", dob: Date.new(1910, 2, 14), sex: "M", hrn: "1001", sensitive: false } ], find("mouse")
    assert_equal({ dfn: 990_001, name: "ALPHA,AVERY", dob: Date.new(1952, 5, 26), sex: "F", hrn: "990001", sensitive: false },
                 find("9999").last, "the row's name is the lookup's; PTINFO adds only the identifiers")
  end

  def test_one_ptinfo_call_per_patient_listed_after_the_lookups
    @client = PtinfoRecorder.new
    RpmsRpc.configure { |c| c.client = @client }

    find("9999")
    assert_equal [ [ "BEHOPTPL LOOKUP", [ "9999" ] ], [ "BEHOPTPL HRNLKP", [ "9999" ] ],
                   [ "BEHOPTCX PTINFO", [ "3" ] ], [ "BEHOPTCX PTINFO", [ "990001" ] ] ], @client.calls
  end

  def test_a_patient_ptinfo_does_not_find_keeps_its_row_with_no_identifiers
    row = RpmsRpc::PatientSelection.send(:with_identifiers, { dfn: 999_999, name: "GONE,PATIENT" })

    assert_equal({ dfn: 999_999, name: "GONE,PATIENT", dob: nil, sex: nil, hrn: nil, sensitive: nil }, row)
  end

  def test_no_row_carries_an_ssn
    %w[mouse 9999 M9999 10012 2/14/1910].each do |query|
      find(query).each { |row| refute row.key?(:ssn), "#{query}: #{row.inspect}" }
    end
  end

  def test_nothing_typed_asks_rpms_nothing
    assert_equal [], find("  ")
    assert_empty @client.calls
  end
end
