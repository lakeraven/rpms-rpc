# frozen_string_literal: true

require "minitest/autorun"
require "yaml"
require "digest"
require "rpms_rpc"
require "rpms_rpc/bmx_client"
require "rpms_rpc/api/registration"
require_relative "../captured_replies"

# rpms-rpc#609 (dev-lead call 2026-11-09): Registration's duplicate lookup
# runs over BMX, where an M error inside AGG LOOKUP PATIENTS is reported,
# never over CIA, where it answers the same bytes as a genuine no-match.
#
# Every reply here was captured from a throwaway container of the pinned build
# as PROFILE,REG: the BMX frames in test/fixtures/bmx/agg-lookup-patients.yml
# (tools/capture_bmx_frames.rb) and the CIA replies in
# test/fixtures/captured_replies/agg-lookup-patients.yml (tools/capture_replies.rb).
# test/live/registration_lookup_bmx_live_test.rb proves the same on the wire.
class RegistrationLookupBrokerTest < Minitest::Test
  BMX_FIXTURE = File.expand_path("../../fixtures/bmx/agg-lookup-patients.yml", __dir__)
  PARAMS = { "AGGPTLNM" => "ZZNOSUCHQX", "AGGPTFNM" => "NOBODY", "AGGPTMNM" => "", "AGGPTSFX" => "",
             "AGGPTDOB" => "02/03/1901" }.freeze
  ATTRS = { name_last: "ZZNOSUCHQX", name_first: "NOBODY", dob: Date.new(1901, 2, 3), sex: "F",
            no_ssn_reason: "N" }.freeze

  # Socket reads served from captured frames; writes are recorded.
  class FrameSocket
    attr_reader :writes

    def initialize(frames)
      @frames = frames.map(&:b)
      @writes = []
    end

    def write(str) = (@writes << str.b) && str.bytesize
    def recv(_n) = @frames.empty? ? "" : @frames.shift
    def flush; end
    def close = @closed = true
    def closed? = !!@closed
    def setsockopt(*); end
  end

  def teardown
    RpmsRpc.reset!
  end

  def bmx_doc
    @bmx_doc ||= YAML.safe_load_file(BMX_FIXTURE).tap do |doc|
      doc.fetch("frames").each do |f|
        raise "#{f['name']}: frame does not match its sha256; re-capture" unless Digest::SHA256.hexdigest(f.fetch("frame").b) == f.fetch("sha256")
      end
    end
  end

  def frame(name) = bmx_doc.fetch("frames").find { |f| f["name"] == name }.fetch("frame")

  # The capture's signed-on identity, as the clients hold it.
  def identity(client, duz:, division: bmx_doc.fetch("division"))
    client.instance_variable_set(:@duz, duz)
    client.instance_variable_set(:@division, division.transform_keys(&:to_sym))
    client.instance_variable_set(:@divisions, bmx_doc.fetch("divisions").map { |d| d.transform_keys(&:to_sym) })
    client
  end

  # A BmxClient signed on as the capture's user, AGGRPC bound, whose wire is
  # the named frames in order.
  def bmx_lookup(*names, duz: bmx_doc.fetch("duz"))
    client = RpmsRpc::BmxClient.new(host: "127.0.0.1", port: 9101)
    client.instance_variable_set(:@socket, FrameSocket.new(names.map { |n| frame(n) }))
    client.instance_variable_set(:@connected, true)
    client.instance_variable_set(:@authenticated, true)
    identity(client, duz: duz)
    client.instance_variable_set(:@current_context, "AGGRPC")
    client.instance_variable_set(:@timeout, 1)
    client
  end

  # The CIA session registration runs on, signed on as the same user.
  def cia_session(script = {}, duz: bmx_doc.fetch("duz"), division: bmx_doc.fetch("division"))
    client = identity(CapturedReplies::ReplayCiaClient.new(script), duz: duz, division: division)
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def duplicate_identity(lookup)
    RpmsRpc::Registration.send(:duplicate_identity, PARAMS.dup, allow_duplicate: nil, lookup_client: lookup)
  end

  # -- why: over CIA the fault and the no-match are the same bytes --------------

  def test_over_cia_a_faulted_lookup_answers_the_bytes_of_a_no_match
    strip_echo = ->(name) { CapturedReplies.raw("agg-lookup-patients", name).byteslice(1..) }
    assert_equal strip_echo.call("no_match"), strip_echo.call("fault"),
                 "after the sequence echo, the CIA fault reply is byte-identical to the no-match reply"
  end

  def test_over_bmx_the_same_fault_carries_the_security_packet
    refute_equal frame("no_match"), frame("fault")
    assert frame("fault").start_with?("7Recording that an error occurred at "), "BMXSEC rides the security packet"
  end

  # -- the lookup over BMX ---------------------------------------------------

  def test_a_no_match_over_bmx_reads_as_no_match
    cia_session
    assert_nil duplicate_identity(bmx_lookup("no_match")), "no candidate: registration may add"
  end

  def test_a_match_over_bmx_is_a_duplicate_for_review
    cia_session
    result = duplicate_identity(bmx_lookup("match"))
    assert_equal :duplicate_identity, result[:error]
    assert_equal [ 2 ], result[:candidate_dfns]
  end

  def test_a_fault_over_bmx_fails_closed
    cia_session
    assert_equal :identity_unverifiable, duplicate_identity(bmx_lookup("fault"))[:error]
  end

  def test_the_lookup_frame_goes_to_the_bmx_client_never_to_the_cia_session
    session = cia_session
    lookup = bmx_lookup("no_match")
    duplicate_identity(lookup)

    assert_empty session.calls, "the CIA session sends nothing for the lookup"
    sent = lookup.instance_variable_get(:@socket).writes
    assert_equal 1, sent.size
    assert_includes sent.first, "AGG LOOKUP PATIENTS"
  end

  # -- register over CIA -----------------------------------------------------

  def test_register_over_cia_without_a_lookup_client_is_unverifiable_and_sends_nothing
    session = cia_session
    result = RpmsRpc::Registration.register(ATTRS)

    assert_equal :identity_unverifiable, result[:error]
    assert_includes result[:message], "with_lookup_client"
    assert_empty session.calls
  end

  def test_only_a_signed_on_bmx_client_can_be_the_lookup_client
    session = cia_session
    assert_raises(ArgumentError) { RpmsRpc::Registration.with_lookup_client(session) { flunk "ran" } }
    unsigned = bmx_lookup("no_match")
    unsigned.instance_variable_set(:@authenticated, false)
    assert_raises(ArgumentError) { RpmsRpc::Registration.with_lookup_client(unsigned) { flunk "ran" } }
    assert_empty session.calls
  end

  def test_register_refuses_a_lookup_client_signed_on_as_another_user
    session = cia_session(duz: "999")
    lookup = bmx_lookup("no_match")
    result = RpmsRpc::Registration.with_lookup_client(lookup) { RpmsRpc::Patient.register(ATTRS) }

    assert_equal :identity_unverifiable, result[:error]
    assert_empty session.calls
    assert_empty lookup.instance_variable_get(:@socket).writes
  end

  # A DUZ is local to its database: the same number on another database is
  # another person, so the division facts must agree too.
  def test_register_refuses_a_lookup_client_bound_to_another_division
    other = bmx_doc.fetch("division").merge("ien" => 1, "station" => "1")
    session = cia_session(division: other)
    lookup = bmx_lookup("no_match")
    result = RpmsRpc::Registration.with_lookup_client(lookup) { RpmsRpc::Patient.register(ATTRS) }

    assert_equal :identity_unverifiable, result[:error]
    assert_empty session.calls
    assert_empty lookup.instance_variable_get(:@socket).writes
  end

  def test_the_lookup_client_scope_restores_when_it_ends
    cia_session
    lookup = bmx_lookup("no_match")
    RpmsRpc::Registration.with_lookup_client(lookup) { nil }
    assert_equal :identity_unverifiable, RpmsRpc::Registration.register(ATTRS)[:error], "outside the scope there is no lookup client"
  end
end
