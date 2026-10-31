# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"

# PatientSelection.find picks VueCentric's lookup from what was typed. The
# replies are as rpms-ydb 7c3119b answered PROFILE,MD (live 2026-10-31).
class PatientSelectionTest < Minitest::Test
  REPLIES = {
    "BEHOPTPL LISTALL" => [ "3^MOUSE,MICKEY M", "990038^NIGHTSHADE,FINLEY", "2^USER,TEST" ],
    "BEHOPTPL HRNLKP" => [ "990001^ALPHA,AVERY^9999   1/1/1980", "3^MOUSE,MICKEY M^9999   2/14/1910" ],
    "BEHOPTPL LOOKUP" => [ "3^MOUSE,MICKEY M^XXX-XX-XXXX   2/14/1910" ],
    "BEHOPTPL DOBLKP" => [ "3^MOUSE,MICKEY M^1001   2/14/1910" ]
  }.freeze

  class Recorder
    attr_reader :calls

    def initialize = @calls = []

    def call_rpc(rpc, *params)
      @calls << [ rpc, params ]
      REPLIES.fetch(rpc)
    end
  end

  def setup
    @client = Recorder.new
    RpmsRpc.configure { |c| c.client = @client }
  end

  def teardown = RpmsRpc.reset!

  def find(text) = RpmsRpc::PatientSelection.find(text)

  def test_a_name_pages_the_index_from_just_before_it_and_keeps_names_that_begin_with_it
    assert_equal [ { dfn: 3, name: "MOUSE,MICKEY M" } ], find("mouse")
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

  def test_nothing_typed_asks_rpms_nothing
    assert_equal [], find("  ")
    assert_empty @client.calls
  end
end
