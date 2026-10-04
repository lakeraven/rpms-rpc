# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc/client"
require "rpms_rpc/api/patient"

# RpmsRpc::Patient mechanics a server cannot show: arguments refused before
# the wire, the age arithmetic, and that brief_header raises a broker
# error instead of answering nil (#363). Every RPC behaviour (search, find,
# find_by_ssn, brief_header, contact, update) is a live spec in
# test/live/patient_live_test.rb and patient_update_live_test.rb (ADR 0009).
#
# No double here returns RPMS data: NoWireClient fails any call that reaches
# it, and RaisingClient only raises.
class PatientTest < Minitest::Test
  # Any RPC that reaches this client is a test failure.
  class NoWireClient
    class WireReached < StandardError; end

    %i[call_rpc call_rpc_lines call_rpc_global_array].each do |name|
      define_method(name) { |rpc, *| raise WireReached, "#{rpc} reached the wire" }
    end
  end

  # A broker error a server cannot be made to raise on demand (<NOLINE> in
  # BEHOPTCX, an <UNDEFINED> in a routine). This double raises it; it never
  # replies.
  class RaisingClient
    def initialize(message, error: RpmsRpc::Client::RpcError) = (@message, @error = message, error)
    def call_rpc(*) = raise(@error, @message)
  end

  def teardown
    RpmsRpc.reset!
  end

  def use(client)
    RpmsRpc.reset!
    RpmsRpc.configure { |cfg| cfg.client = client }
  end

  # -- refused before the wire ----------------------------------------------

  def test_find_sends_nothing_for_a_blank_or_non_positive_dfn
    use NoWireClient.new
    [ nil, 0, -5, "" ].each { |dfn| assert_nil RpmsRpc::Patient.find(dfn), dfn.inspect }
  end

  def test_find_by_ssn_sends_nothing_for_a_blank_ssn
    use NoWireClient.new
    [ nil, "" ].each { |ssn| assert_nil RpmsRpc::Patient.find_by_ssn(ssn), ssn.inspect }
  end

  def test_brief_header_sends_nothing_for_a_blank_or_non_positive_dfn
    use NoWireClient.new
    [ nil, 0, -5 ].each { |dfn| assert_nil RpmsRpc::Patient.brief_header(dfn), dfn.inspect }
  end

  def test_contact_sends_nothing_for_a_blank_or_non_positive_dfn
    use NoWireClient.new
    [ nil, 0, "-5" ].each { |dfn| assert_nil RpmsRpc::Patient.contact(dfn), dfn.inspect }
  end

  def test_update_with_no_fields_sends_nothing
    use NoWireClient.new
    result = RpmsRpc::Patient.update(42)

    refute result[:success]
    assert_equal :no_fields, result[:error]
  end

# -- errors propagate (#363) ------------------------------------------------

# Before #363 these answered nil: a missing chart banner looked like a
# patient with no banner.
def test_brief_header_raises_when_the_rpc_is_not_served
  use RaisingClient.new("3 Unknown remote procedure: BEHOPTCX PTINFO", error: RpmsRpc::Client::RpcNotAvailableError)
  assert_raises(RpmsRpc::Client::RpcNotAvailableError) { RpmsRpc::Patient.brief_header(8791) }
end

def test_brief_header_raises_when_the_routine_is_missing
  use RaisingClient.new("M  ERROR=<NOLINE>PTINFO+22 BEHOPTCX")
  err = assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Patient.brief_header(8791) }
  assert_includes err.message, "NOLINE"
end

def test_brief_header_raises_any_other_m_error
    use RaisingClient.new("M  ERROR=<UNDEFINED>FOO+5^XYZ^")
    err = assert_raises(RpmsRpc::Client::RpcError) { RpmsRpc::Patient.brief_header(8791) }
    assert_includes err.message, "UNDEFINED"
  end

  # -- age arithmetic --------------------------------------------------------

  def test_age_from_counts_whole_years_around_the_birthday
    dob = Date.new(1986, 7, 1)
    assert_equal 39, RpmsRpc::Patient.age_from(dob, today: Date.new(2026, 6, 30)), "day before"
    assert_equal 40, RpmsRpc::Patient.age_from(dob, today: Date.new(2026, 7, 1)), "on the day"
    assert_equal 40, RpmsRpc::Patient.age_from(dob, today: Date.new(2026, 7, 2)), "day after"
    assert_equal 39, RpmsRpc::Patient.age_from(dob, today: Date.new(2026, 5, 22))
    assert_nil RpmsRpc::Patient.age_from(nil)
  end
end
