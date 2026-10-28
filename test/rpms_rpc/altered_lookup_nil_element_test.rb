# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"

# rpms-rpc#463, Fable review: Reply.from_wire passes non-String elements
# through, and DataMapper#parse_many has always skipped a nil line. When the
# reply says it replaced a byte, Patient.lookup must still skip the nil and
# return the real row flagged altered: it must not raise. Every byte string
# below is SYNTHETIC.
class RpmsRpc::AlteredLookupNilElementTest < Minitest::Test
  HEADER = "I00010DFN^T00030PATIENT_NAME^T00030HRN^T00009SSN^" \
           "D00030DOB^D00030DOD^T00003SENS_FLAG^T01024ALIAS^T00001INACTIVE"

  def teardown
    RpmsRpc.reset!
  end

  def altered_row = "3^DO\xC9,JANE^104827^000009999^05/15/1980^^^^N".b
  def clean_row = "3^DOE,JANE^104827^000009999^05/15/1980^^^^N".b

  def lookup_over(lines)
    reply = RpmsRpc::Reply.from_wire(lines)
    client = Object.new
    client.define_singleton_method(:call_rpc) { |*| reply }
    RpmsRpc.configure { |c| c.client = client }
    RpmsRpc::Patient.lookup("DO")
  end

  def test_a_nil_element_before_an_altered_row_is_skipped_and_the_row_is_flagged
    rows = lookup_over([ nil, altered_row ])

    assert_equal [ [ "DO�,JANE", true ] ], rows.map { |row| [ row[:name], row[:altered] ] }
  end

  def test_a_nil_element_between_a_header_and_an_altered_row_is_skipped
    rows = lookup_over([ HEADER, nil, altered_row ])

    assert_equal [ [ "DO�,JANE", true ] ], rows.map { |row| [ row[:name], row[:altered] ] }
  end

  def test_a_nil_element_after_an_altered_row_is_skipped
    rows = lookup_over([ HEADER, altered_row, nil ])

    assert_equal [ [ "DO�,JANE", true ] ], rows.map { |row| [ row[:name], row[:altered] ] }
  end

  def test_a_nil_element_beside_clean_rows_changes_nothing
    rows = lookup_over([ nil, clean_row ])

    assert_equal [ [ "DOE,JANE", false ] ], rows.map { |row| [ row[:name], row[:altered] ] }
  end
end
