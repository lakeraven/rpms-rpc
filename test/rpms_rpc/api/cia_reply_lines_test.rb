# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/cia_client"
require "rpms_rpc/version"
require "rpms_rpc/api/patient"
require "rpms_rpc/api/authentication"

# The DataMapper fetch_* paths read CiaClient#call_rpc. It returned
# printable(raw): the sequence echo + ack became leading text, CR/LF became
# spaces and the \x01 error flag became data (#195). Seen live on a YDB
# stack's CIA broker:
#
#   - ORWPT LIST ALL "DEMO" (9 rows) -> ONE patient: the frame byte "8" as the
#     DFN and the first row's name, a wrong-patient pairing;
#   - ORWPT FULLSSN for an SSN on no patient -> a match;
#   - ORWU USERKEYS, unregistered there -> the refusal text as the user's one
#     security key, and the capability probe saying the RPC exists.
class RpmsRpc::CiaReplyLinesTest < Minitest::Test
  EOD = RpmsRpc::Client::EOD

  class FakeSocket
    def initialize(reads)
      @reads = reads.dup
    end

    def recv(_n) = @reads.empty? ? "" : @reads.shift
    def write(str) = str.bytesize
    def flush; end
    def close = @closed = true
    def closed? = !!@closed
    def setsockopt(*); end
  end

  def cia_client(reads)
    c = RpmsRpc::CiaClient.new
    c.instance_variable_set(:@socket, FakeSocket.new(reads))
    c.instance_variable_set(:@connected, true)
    c.instance_variable_set(:@timeout, 1)
    c.instance_variable_set(:@seq, 0)
    c.instance_variable_set(:@session_uid, "1")
    c
  end

  def use(reads)
    RpmsRpc.configure { |c| c.client = cia_client(reads) }
  end

  def teardown
    RpmsRpc.reset!
  end

  def test_a_patient_list_parses_one_patient_per_row_with_its_own_dfn
    use([ "8\x003^MOUSE,MICKEY M^^^^MOUSE,MICKEY M\r2^USER,TEST^^^^USER,TEST\r7^ZZBIRTH,REGISTER^^^^ZZBIRTH,REGISTER\r#{EOD}" ])

    found = RpmsRpc::Patient.search("DEMO").map { |p| [ p[:dfn], p[:name] ] }

    assert_equal [ [ 3, "MOUSE,MICKEY M" ], [ 2, "USER,TEST" ], [ 7, "ZZBIRTH,REGISTER" ] ], found
  end

  def test_an_ssn_on_no_patient_finds_no_patient
    use([ "5\x00#{EOD}" ])

    assert_nil RpmsRpc::Patient.find_by_ssn("000000000")
  end

  def test_an_ssn_on_file_finds_that_patient
    use([ "5\x003^MOUSE,MICKEY M^2100214^000009999\r\n#{EOD}" ])

    found = RpmsRpc::Patient.find_by_ssn("000009999")

    assert_equal 3, found[:dfn]
    assert_equal "MOUSE,MICKEY M", found[:name]
  end

  def test_an_unregistered_key_rpc_yields_no_keys_not_its_refusal
    use([ "6\x013 Unknown remote procedure: ORWU USERKEYS#{EOD}" ])

    assert_equal [], RpmsRpc::Authentication.user_security_keys("4")
  end

  def test_the_capability_probe_reads_a_cia_refusal_as_missing
    use([ "6\x013 Unknown remote procedure: ORWU USERKEYS#{EOD}" ])

    refute RpmsRpc.client.supports?(:user_security_keys_list)
  end
end
