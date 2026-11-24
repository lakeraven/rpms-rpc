# frozen_string_literal: true

require "rpms_rpc/api/problem"

# The stock ORQQPL reads Problem.lex_search, .audit_history and .comments
# make, as PROFILE,MD. Setup files one problem for synthetic seed patient
# DFN 990055 through Problem.add (BGOPROB SET, as problem-write.rb does), then
# removes it with ORQQPL DELETE, whose reason is filed as the problem's note
# (NEWNOTE^GMPLSAVE) and whose change is audited (AUDIT^GMPLX), and puts it
# back with ORQQPL REPLACE, a second audited change. Run on a fresh
# throwaway container: each run files one more problem. rpms-rpc#620, #872.
Problem = RpmsRpc::Problem
FILED = {} # the problem setup files, for the flows

CAPTURE = {
  rpc: "ORQQPL PROBLEM LEX SEARCH", entry_point: "LEXSRCH^ORQQPL1",
  signed_on_as: "PROFILE,MD (PMD123, a published demo pair; DUZ 206)",
  access: "PMD123", verify: "PMD123!!",
  note: "Setup files one problem for synthetic DFN 990055 (Problem.add: ICD F32.9, location 7819), " \
        "removes it (ORQQPL DELETE, reason 'Entered in error') and puts it back (ORQQPL REPLACE). " \
        "Problem 1 is seed patient DFN 2's, with no history or notes.",
  setup: lambda { |client|
    RpmsRpc.configure { |cfg| cfg.client = client }
    added = Problem.add(990_055, icd_code: "F32.9", description: "SYNTH CAPTURE HISTORY", location_ien: "7819",
                                 status: "Chronic", onset_date: "11/01/2026")
    abort "setup: Problem.add did not file the problem: #{added.inspect}" unless added[:success]
    ien = added[:ien].to_s
    deleted = client.call_rpc("ORQQPL DELETE", ien, "206", "7819", "Entered in error").first.to_s
    abort "setup: ORQQPL DELETE answered #{deleted.inspect}" unless deleted == "1"
    replaced = client.call_rpc("ORQQPL REPLACE", ien).first.to_s
    abort "setup: ORQQPL REPLACE answered #{replaced.inspect}" unless replaced == "1"
    FILED[:ien] = ien
    {}
  },
  flows: {
    "lex_search" => { about: "lex_search for 'diabetes': 100 Lexicon rows and the match count",
                      run: -> { Problem.lex_search("diabetes") } },
    "lex_search_none" => { about: "lex_search for 'zzqqxx': no match", run: -> { Problem.lex_search("zzqqxx") } },
    "audit_history" => { about: "audit_history of the problem setup filed: removed, then placed back",
                         run: -> { Problem.audit_history(FILED.fetch(:ien)) } },
    "audit_history_none" => { about: "audit_history of problem 1: NONE", run: -> { Problem.audit_history(1) } },
    "comments" => { about: "comments of the problem setup filed: the removal reason",
                    run: -> { Problem.comments(FILED.fetch(:ien)) } },
    "comments_none" => { about: "comments of problem 1: no notes", run: -> { Problem.comments(1) } }
  }
}.freeze
