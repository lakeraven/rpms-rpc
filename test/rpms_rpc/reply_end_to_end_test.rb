# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/xwb_client"
require "rpms_rpc/bmx_client"
require "rpms_rpc/cia_client"
require_relative "captured_replies"

# rpms-rpc#463, panel round: the altered flag has to reach the HOST, not stop
# at #call_rpc. A host reads identity-bearing text (an allergen name, a patient
# name) through RpmsRpc::Allergy and RpmsRpc::Patient, and the gem transforms
# the reply into hashes on the way. Altered text must NEVER read as unaltered:
# two distinct byte strings that collapse into one identical-looking string
# must each say they were altered.
#
# Contract for hosts (additive): every row Allergy.assessment / Allergy.for_patient
# and Patient.lookup return carries `altered: true|false`. It is true when any
# text of that row had a byte replaced to become valid UTF-8.
#
# CHARSET: stored bytes, read as UTF-8 (see Reply). Every byte string below is
# SYNTHETIC.
class RpmsRpc::ReplyEndToEndTest < Minitest::Test
  EOD = RpmsRpc::Client::EOD
  EOT = RpmsRpc::Client::EOT

  LOOKUP_HEADER = "I00010DFN^T00030PATIENT_NAME^T00030HRN^T00009SSN^" \
                  "D00030DOB^D00030DOD^T00003SENS_FLAG^T01024ALIAS^T00001INACTIVE"

  class FakeSocket
    def initialize(reads) = (@reads = reads.dup)
    def write(str) = str.bytesize
    def recv(_n) = @reads.empty? ? "" : @reads.shift.b
    def flush; end
    def close = @closed = true
    def closed? = !!@closed
    def setsockopt(*); end
  end

  def teardown
    RpmsRpc.reset!
  end

  def wired(client, reads)
    client.instance_variable_set(:@socket, FakeSocket.new(reads))
    client.instance_variable_set(:@connected, true)
    client.instance_variable_set(:@timeout, 1)
    client
  end

  def lookup_row(name) = "3^#{name}^104827^000009999^05/15/1980^^^^N".b
  def lookup_blob(*rows) = ("5\x00" + LOOKUP_HEADER + "\x1e\n" + rows.join("\x1e\n") + "\x1e\n\x1f\n").b

  # -- 1. Allergy rows carry the flag, and equal-looking allergens are each flagged

  # A clean reply: ORQQAL LIST as the build answered it for the seed patient
  # (data-mapper-fetch.yml, flow allergies_for_patient).
  def replay_allergies
    client = CapturedReplies::ReplayCiaClient.new(CapturedReplies.flow_script("data-mapper-fetch", "allergies_for_patient"))
    RpmsRpc.configure { |c| c.client = client }
    client
  end

  # No build stores an allergen whose bytes are not UTF-8, so these replies
  # are SYNTHETIC bytes in the captured row layout (IEN^ALLERGEN^SEVERITY^SIGNS),
  # read through CiaClient's own reply grammar.
  def replay_allergy_rows(*rows)
    client = CapturedReplies::ReplayCiaClient.new("ORQQAL LIST" => [ ("5\x00" + rows.map { |row| "#{row}\r" }.join).b ])
    RpmsRpc.configure { |c| c.client = client }
    client
  end

  def test_two_distinct_altered_allergens_each_say_they_were_altered
    replay_allergy_rows("1^PENICILL\xCDN^^HIVES".b, "2^PENICILL\xCEN^^HIVES".b)

    rows = RpmsRpc::Allergy.for_patient(2)

    assert_equal 2, rows.size
    assert_equal rows[0][:allergen], rows[1][:allergen], "the two distinct byte strings now look identical"
    assert rows.all? { |row| row[:altered] }, "each row must say its text was altered"
    assert rows.all? { |row| row[:allergen].valid_encoding? && row[:allergen].encoding == Encoding::UTF_8 }
  end

  def test_a_clean_allergy_row_is_not_altered_and_an_altered_neighbour_is
    replay_allergy_rows("1^PENICILLIN^^HIVES", "2^SULFA\xCD^^HIVES".b)

    rows = RpmsRpc::Allergy.for_patient(2)

    assert_equal [ false, true ], rows.map { |row| row[:altered] }
    assert_equal "PENICILLIN", rows[0][:allergen]
  end

  def test_allergy_assessment_rows_keep_their_existing_keys_and_add_altered
    client = replay_allergies

    row = RpmsRpc::Allergy.assessment(2)[:allergies].first

    assert_equal({ ien: "1", allergen: "PENICILLIN", severity: nil, signs: "HIVES", altered: false }, row)
    assert_equal [ [ "ORQQAL LIST", [ "2" ] ] ], client.calls.map { |c| [ c[:rpc], c[:params] ] }
  end

  # -- 2. Patient.lookup rows carry the flag, over every route a reply can take

  def test_lookup_over_a_global_array_client_flags_the_altered_row_only
    payload = lookup_blob(lookup_row("DOE,JANE"), lookup_row("DO\xC9,JOHN".b))
    client = Object.new
    client.define_singleton_method(:call_rpc_global_array) { |*| payload }
    RpmsRpc.configure { |c| c.client = client }

    rows = RpmsRpc::Patient.lookup("DO")

    assert_equal [ false, true ], rows.map { |row| row[:altered] }
    assert rows.all? { |row| row[:name].valid_encoding? && row[:name].encoding == Encoding::UTF_8 }
  end

  def test_lookup_over_a_line_reply_client_flags_the_altered_row
    # XWB and BMX answer with ONE element holding the whole framed blob.
    reply = RpmsRpc::Reply.from_wire([ lookup_blob(lookup_row("DO\xC9,JANE".b)) ])
    client = Object.new
    client.define_singleton_method(:call_rpc) { |*| reply }
    RpmsRpc.configure { |c| c.client = client }

    rows = RpmsRpc::Patient.lookup("DO")

    assert_equal 1, rows.size
    assert_equal true, rows.first[:altered]
    assert_equal "DO�,JANE", rows.first[:name]
  end

  def test_lookup_of_clean_rows_says_altered_false
    payload = lookup_blob(lookup_row("DOE,JANE"))
    client = Object.new
    client.define_singleton_method(:call_rpc_global_array) { |*| payload }
    RpmsRpc.configure { |c| c.client = client }

    assert_equal [ false ], RpmsRpc::Patient.lookup("DO").map { |row| row[:altered] }
  end

  # -- 3. GLOBAL ARRAY replies are valid UTF-8 with the alteration recorded

  def test_cia_global_array_reply_is_valid_utf8_and_says_altered
    body = lookup_blob(lookup_row("DO\xC9,JANE".b))
    cia = wired(RpmsRpc::CiaClient.new, [ "1\x00".b + body + "\x1f".b + RpmsRpc::Client::EOD.b ])
    cia.instance_variable_set(:@seq, 0)

    raw = cia.call_rpc_global_array("AGG LOOKUP PATIENTS", "DO")

    assert_equal Encoding::UTF_8, raw.encoding
    assert raw.valid_encoding?
    assert RpmsRpc::Reply.altered?(raw), "a replaced byte in a global array reply must be reported"
    assert_equal "x — #{raw}", [ "x", raw ].join(" — ") # joining with a UTF-8 literal does not raise
  end

  def test_cia_global_array_reply_of_clean_text_is_unaltered_and_equals_the_wire_text
    body = RpmsRpc::ReplyEndToEndTest::LOOKUP_HEADER + "\x1e" + "3^DOE,JANE^1^2^3\x1e\x1f"
    cia = wired(RpmsRpc::CiaClient.new, [ "1\x00".b + body.b + RpmsRpc::Client::EOD.b ])
    cia.instance_variable_set(:@seq, 0)

    raw = cia.call_rpc_global_array("AGG LOOKUP PATIENTS", "DO")

    assert_equal false, RpmsRpc::Reply.altered?(raw)
    assert_equal Encoding::UTF_8, raw.encoding
  end

  # -- 4. Client#call_rpc_lines

  class StandIn < RpmsRpc::Client
    def initialize(reply) = (@stand_in_reply = reply)
    def call_rpc(*) = @stand_in_reply
    def read_response = nil
  end

  def test_call_rpc_lines_does_not_crash_on_a_utf8_tagged_string_with_an_invalid_byte
    lines = StandIn.new(+"ok\ncaf\xE9 X").call_rpc_lines("SYNTHETIC RPC")

    assert_equal [ "ok", "caf� X" ], lines.to_a
    assert_equal [ 1 ], lines.altered_lines
  end

  def test_call_rpc_lines_converts_a_plain_array_and_reports_the_alteration
    lines = StandIn.new([ "a", "caf\xE9".b ]).call_rpc_lines("SYNTHETIC RPC")

    assert_kind_of RpmsRpc::Reply, lines
    assert lines.all? { |line| line.encoding == Encoding::UTF_8 && line.valid_encoding? }
    assert_equal [ 1 ], lines.altered_lines
  end

  # -- 6. Reply hardening

  def test_a_reply_and_its_lines_are_frozen
    reply = RpmsRpc::Reply.from_wire([ "a", "caf\xE9".b ])

    assert reply.frozen?
    assert reply.all?(&:frozen?)
    assert_raises(FrozenError) { reply.shift }
    assert_raises(FrozenError) { reply << "x" }
  end

  def test_wrapping_an_altered_reply_again_keeps_the_flag
    once = RpmsRpc::Reply.from_wire([ "ok", "caf\xE9".b ])
    twice = RpmsRpc::Reply.from_wire(once)

    assert twice.altered?, "re-wrapping must not launder an alteration"
    assert_equal [ 1 ], twice.altered_lines
  end

  def test_a_reply_cannot_be_built_without_decoding_its_lines
    assert_raises(NoMethodError) { RpmsRpc::Reply.new([ "caf\xE9".b ]) }
  end

  def test_a_copy_of_a_reply_is_a_plain_array_never_a_mutable_reply_with_stale_indexes
    reply = RpmsRpc::Reply.from_wire([ "hdr", "caf\xE9".b, "ok" ])

    [ reply.dup, reply.clone ].each do |copy|
      assert_instance_of Array, copy, "a copy of a Reply must not be a mutable Reply"
      copy.shift
      assert_equal false, RpmsRpc::Reply.altered?(copy)
    end
    assert_equal [ 1 ], reply.altered_lines, "the original is untouched"
  end

  def test_altered_is_false_for_things_that_are_not_replies
    assert_equal false, RpmsRpc::Reply.altered?([ "caf\xE9".b ])
    assert_equal false, RpmsRpc::Reply.altered?("plain")
    assert_equal false, RpmsRpc::Reply.altered?(nil)
  end
end
