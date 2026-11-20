# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/problem"
require_relative "../captured_replies"

class ProblemTest < Minitest::Test
  DFN = "8791"

  def teardown
    RpmsRpc.reset!
  end

  # RETIRED — Problem.filter and the :problem_filter mapping are gone.
  #
  # The #8994 registry binds "BGOPROB GET CLASS" to DICLASS^BGOASLK
  # (.broker_dumps_8994_20260607.txt:3103 "BGOPROB GET CLASS^DICLASS^
  # BGOASLK^2"), which is "Get the classifications for an asthma DX"
  # (BGOASLK.m:52-67). It takes ONE param — "ICD ^ SNOMED ^ class type"
  # (BGOASLK.m:53) — returns "" unless $$CHECK^BGOASLK says the dx is
  # asthma (BGOASLK.m:58-60), and emits TWO-piece rows read out of
  # ^APCDPLCL (BGOASLK.m:65: $P(CTYPE,U,1)_"^"_$P(CTYPE,U,2)).
  #
  # It is not a problem list, it is not scoped by patient, and it never
  # took a DFN. The old wrapper sent (DFN, scope_code) and declared a
  # ten-piece ORQQPL problem-list row over the reply; its "IPL scope
  # classes" C/E/R/I appear nowhere in the routine. Same invented-capability
  # class as the retired BHDPTRPC family (#174/#184).
  def test_problem_filter_mapping_is_not_registered
    refute_respond_to RpmsRpc::DataMapper, :problem_filter,
      "an asthma-classification RPC must not be registered as a problem-list filter"
  end

  # Nothing else may quietly re-bind the name to the old shape either.
  def test_no_mapping_claims_bgoprob_get_class
    registry = RpmsRpc::DataMapper.instance_variable_get(:@registry)
    claimed = registry.values.select { |m| m.rpc_name == "BGOPROB GET CLASS" }

    assert_empty claimed,
      "BGOPROB GET CLASS is DICLASS^BGOASLK — bind it deliberately or not at all"
  end

  def test_problem_no_longer_exposes_the_fabricated_scope_filter
    refute_respond_to RpmsRpc::Problem, :filter
    refute RpmsRpc::Problem.const_defined?(:SCOPE_CODES, false),
      "the invented IPL scope codes are gone with the method"
  end

  # ORQQPL stock-VistA surface (rr-txz)

  # LEXSRCH^ORQQPL1's rows are "lexicon IEN^text^ICD code^ICD IEN^coding
  # system", then a match-count line. The replies are
  # test/fixtures/captured_replies/problem-orqqpl-reads.yml (#872).
  ORQQPL_SLUG = "problem-orqqpl-reads"

  def replay_orqqpl(flow) = replay_detail(CapturedReplies.flow_script(ORQQPL_SLUG, flow))

  def test_lex_search_reads_each_lexicon_row_and_not_the_match_count
    client = replay_orqqpl("lex_search")

    rows = RpmsRpc::Problem.lex_search("diabetes")

    assert_equal 100, rows.length, "100 matches, not the '669 matches found' line"
    assert_equal({ ien: "33570", description: "Diabetes", code: nil, code_ien: nil, coding_system: nil }, rows.first)
    assert_equal "Type 2 Diabetes Mellitus without Complications", rows.find { |r| r[:ien] == "5002666" }[:description]
    refute rows.any? { |r| r[:description].to_s.include?("matches found") }
    assert_equal CapturedReplies.flow_calls(ORQQPL_SLUG, "lex_search"), detail_calls(client)
  end

  def test_lex_search_with_no_match_is_empty
    replay_orqqpl("lex_search_none")

    assert_equal [], RpmsRpc::Problem.lex_search("zzqqxx")
  end

  def test_lex_search_returns_empty_for_blank_text
    client = replay_detail({})

    assert_equal [], RpmsRpc::Problem.lex_search("")
    assert_equal [], RpmsRpc::Problem.lex_search("   ")
    assert_empty detail_calls(client)
  end

  # === details (ORQQPL DETAIL) ===
  #
  # DETAIL(Y,DFN,PROBIEN,ID) (ORQQPL.m:21): the patient comes first and the
  # problem IEN third (#259). DETAIL builds a display report, one text line
  # per Y(I) (ORQQPL.m:26-59), and never reads DFN. The replies are
  # test/fixtures/captured_replies/problem-detail.yml, captured live as
  # PROVIDER,TEST on the seeded problem 1 (#821).

  DETAIL_SLUG = "problem-detail"
  SEEDED_DETAIL = [
    "*TYPE 2 DIABETES MELLITUS (Invalid Code (not found in the ICD-9-CM system))",
    "*** The ICD code Invalid Code (not found in the ICD-9-CM system) is currently inactive. ***",
    " ", "   Onset: 4/10/23", "  Status: ACTIVE", " SC Cond: UNKNOWN", "Exposure: None", " ",
    "Provider: DEMO,DOCTOR", "  Clinic: ", " ",
    "Recorded: 11/19/26, by DEMO,DOCTOR", " Entered: 11/19/26, by DEMO,DOCTOR", " Updated: 11/19/26", " ", " "
  ].join("\n").freeze

  def replay_detail(script)
    client = CapturedReplies::ReplayCiaClient.new(script)
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def detail_calls(client) = client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params] ] }

  def test_details_is_the_report_text_for_any_patient
    %w[details_seed details_other_patient].zip([ 2, 4 ]).each do |flow, dfn|
      client = replay_detail(CapturedReplies.flow_script(DETAIL_SLUG, flow))

      assert_equal SEEDED_DETAIL, RpmsRpc::Problem.details(dfn, 1), flow
      assert_equal CapturedReplies.flow_calls(DETAIL_SLUG, flow), detail_calls(client)
    end
  end

  def test_details_of_a_problem_not_on_file_raises_the_m_error
    replay_detail("ORQQPL DETAIL" => [ CapturedReplies.raw(DETAIL_SLUG, "unknown_problem") ])

    error = assert_raises(RpmsRpc::Client::RpcMError) { RpmsRpc::Problem.details(2, 999_999_999) }
    assert_includes error.message, "LVUNDEF"
  end

  def test_details_with_an_invalid_id_reaches_no_wire
    client = replay_detail(CapturedReplies.flow_script(DETAIL_SLUG, "details_seed"))

    assert_nil RpmsRpc::Problem.details(DFN, nil)
    assert_nil RpmsRpc::Problem.details(DFN, "0")
    assert_nil RpmsRpc::Problem.details(nil, "5001")
    assert_nil RpmsRpc::Problem.details("0", "5001")
    assert_empty detail_calls(client)
  end

  # HIST^ORQQPL2: a count line, then "date^text" per change; NONE for none.
  def test_audit_history_reads_each_change_and_not_the_count
    client = replay_orqqpl("audit_history")
    ien = CapturedReplies.flow_calls(ORQQPL_SLUG, "audit_history").first.last.first

    assert_equal [ { date: "11/20/26", text: "PROBLEM removed by PROFILE,MD" },
                   { date: "11/20/26", text: "PROBLEM placed back on list by PROFILE,MD" } ],
                 RpmsRpc::Problem.audit_history(ien)
    assert_equal CapturedReplies.flow_calls(ORQQPL_SLUG, "audit_history"), detail_calls(client)
  end

  def test_audit_history_none_is_empty
    replay_orqqpl("audit_history_none")

    assert_equal [], RpmsRpc::Problem.audit_history(1)
  end

  # GETCOMM^ORQQPL2: one line per active note, the text alone.
  def test_comments_reads_each_note
    client = replay_orqqpl("comments")
    ien = CapturedReplies.flow_calls(ORQQPL_SLUG, "comments").first.last.first

    assert_equal [ { comment: "Entered in error" } ], RpmsRpc::Problem.comments(ien)
    assert_equal [ [ "ORQQPL PROB COMMENTS", [ ien ] ] ], detail_calls(client)
  end

  def test_comments_none_is_empty
    replay_orqqpl("comments_none")

    assert_equal [], RpmsRpc::Problem.comments(1)
  end

  def test_audit_history_and_comments_with_an_invalid_id_reach_no_wire
    client = replay_detail({})

    [ nil, "", "0", -5, "abc" ].each do |ien|
      assert_equal [], RpmsRpc::Problem.audit_history(ien)
      assert_equal [], RpmsRpc::Problem.comments(ien)
    end
    assert_empty detail_calls(client)
  end
end
