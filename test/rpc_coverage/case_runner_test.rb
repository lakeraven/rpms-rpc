# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../../tools/rpc_coverage/case_runner"

# rake rpc:cases: rpms-ops' wire-level cases (rpms-ops#834), read as data and run through
# call_rpc_raw. Offline: a fake client answers with raw CIA replies (seq echo, flag, body).
class CaseRunnerTest < Minitest::Test
  Cases = RpcCoverage::Cases

  class FakeClient
    attr_reader :sent

    def initialize(replies)
      @replies = replies
      @sent = []
      @up = true
    end

    def connected? = @up
    def authenticated? = @up
    def disconnect = (@up = false)

    def create_context(option) = (@context = option)

    def call_rpc_raw(rpc, *params)
      @sent << [ @context, rpc, params ]
      reply = @replies.fetch(rpc)
      raise reply if reply.is_a?(Exception)

      reply
    end
  end

  def row(id, rpc, expect: "answered", params: [], **extra)
    { "id" => id, "rpc" => rpc, "context" => "CIAV VUECENTRIC", "persona" => "programmer",
      "params" => params, "expect" => expect }.merge(extra.transform_keys(&:to_s))
  end

  def run_rows(rows, replies, leftover: "")
    client = FakeClient.new(replies)
    runner = Cases::Runner.new(rows, connect: -> { client }, duz: "4", leftover: ->(_c) { leftover })
    runner.run
    [ runner, client ]
  end

  def test_a_capture_feeds_a_later_case_and_duz_is_the_signed_on_user
    rows = [ row("patients", "ORWPT LIST ALL", params: %w[@~ 1], capture: { "dfn" => 1 }, min_rows: 1),
             row("vitals", "ORQQVI VITALS", params: [ "${patients.dfn}" ]),
             row("roots", "TIU TEMPLATE GETROOTS", params: [ "${duz}" ]) ]
    replies = { "ORWPT LIST ALL" => "5\x00HEADER^X\r\n990051^ALPHA,AVERY\r\n990001^ALPHA,CASEY\r\n",
                "ORQQVI VITALS" => "6\x00378^BP^134/84\r\n", "TIU TEMPLATE GETROOTS" => "7\x00" }
    runner, client = run_rows(rows, replies)

    assert runner.passed?, runner.results.inspect
    assert_equal [ "990051" ], client.sent[1][2]
    assert_equal [ "4" ], client.sent[2][2]
    assert_equal({ "dfn" => "990051" }, runner.results[0]["captured"])
    assert_equal [ 3, 1, 0 ], runner.results.map { |r| r["rows"] }
  end

  def test_a_list_parameter_becomes_a_hash_with_one_or_several_subscripts
    params = [ { "list" => [ [ "FILE", "9000001" ], [ "IENS", "${p.dfn}," ], [ "1", "0", "|NAME|" ] ] } ]
    wire = Cases.wire_params(params, { "p" => { "dfn" => "7" } }, "4")
    assert_equal [ { "FILE" => "9000001", "IENS" => "7,", [ "1", "0" ] => "|NAME|" } ], wire
  end

  def test_the_verdict_is_the_flag_byte
    assert_equal "answered", Cases.reply("1\x00")[0]
    assert_equal "no_data", Cases.reply("1")[0]
    verdict, _, detail = Cases.reply("1\x01The server has reported the following error:\r\nERR+9^ORWRP")
    assert_equal "broker_error", verdict
    assert_includes detail, "ERR+9^ORWRP"
    assert_equal [ "A", "B" ], Cases.reply("1\x00A\x1eB\x1e\x1f")[1]
  end

  def test_an_unexpected_verdict_fails_and_an_expected_error_passes
    rows = [ row("summary", "ORWRP REPORT TEXT"), row("refs", "BMC SEARCH REFERRAL", expect: "broker_error") ]
    err = "1\x01The server has reported the following error:"
    runner, = run_rows(rows, { "ORWRP REPORT TEXT" => err, "BMC SEARCH REFERRAL" => err })

    refute runner.passed?
    assert_equal [ false, true ], runner.results.map { |r| r["pass"] }
  end

  def test_a_missing_capture_fails_its_case_and_leaves_the_dependent_unresolved
    rows = [ row("patients", "ORWPT LIST ALL", capture: { "dfn" => 1 }), row("vitals", "ORQQVI VITALS", params: [ "${patients.dfn}" ]) ]
    runner, client = run_rows(rows, { "ORWPT LIST ALL" => "1\x00", "ORQQVI VITALS" => "2\x00" })

    assert_equal [ false, false ], runner.results.map { |r| r["pass"] }
    assert_equal "unresolved", runner.results[1]["verdict"]
    assert_equal 1, client.sent.size, "an unresolved case must not reach the wire"
  end

  def test_bytes_left_on_the_socket_are_a_desync
    runner, = run_rows([ row("visits", "AMHG GET VISITS") ], { "AMHG GET VISITS" => "1\x00A\x1e" }, leftover: "\x7f")
    assert_equal "stream_desync", runner.results[0]["verdict"]
    refute runner.passed?
  end

  def test_min_rows_fails_a_short_answer
    runner, = run_rows([ row("tribes", "DDR LISTER", min_rows: 1) ], { "DDR LISTER" => "1\x00" })
    refute runner.results[0]["pass"]
    assert_match(/fewer than min_rows 1/, runner.results[0]["detail"])
  end

  def test_the_file_is_checked_for_shape_and_reference_order
    rows = [ row("b", "X", params: [ "${a.dfn}" ]), row("a", "Y", capture: { "dfn" => 1 }),
             row("a", "Z", expect: "maybe"), row("Bad_Id", "W", extra: 1) ]
    problems = Cases.problems(rows)
    assert(problems.any? { |p| p.include?("${a.dfn}, which no earlier case captures") })
    assert(problems.any? { |p| p.include?("duplicate id") })
    assert(problems.any? { |p| p.include?("expect \"maybe\"") })
    assert(problems.any? { |p| p.include?("not lower-case-hyphenated") })
    assert(problems.any? { |p| p.include?("unknown keys extra") })
  end

  def test_load_refuses_a_line_that_is_not_json
    Tempfile.create([ "cases", ".jsonl" ]) do |f|
      f.write(JSON.generate(row("a", "X")) + "\n{nope\n")
      f.flush
      assert_raises(Cases::Error) { Cases.load(f.path) }
    end
  end
end
