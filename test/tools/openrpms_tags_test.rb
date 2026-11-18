# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../../tools/openrpms_tags"

# tools/openrpms_tags.rb, the decisions behind .github/workflows/openrpms-tags.yml (rpms-rpc#724): which published
# openrpms release takes which rpms-rpc tag. The fixtures are real assets from lakeraven/openrpms, downloaded as
# published: both 2a9b3fe harness records, the 2a9b3fe-ydb per-RPC record (rpms-rpc-live v1), and the releases list
# for 2a9b3fe, 3f5487a and both 312e774 tags (asset names only). No published release carries a train record yet, so the
# train-shaped records are the real ydb one with the fields bin/rpms_rpc_harness.sh record and
# bin/rpms_rpc_record.rb write in openrpms.
class OpenrpmsTagsTest < Minitest::Test
  T = OpenrpmsTags
  DIR = File.expand_path("../fixtures/openrpms_tags", __dir__)
  YDB = "bcer-9.0-20261116-2a9b3fe-ydb"
  IRIS = "bcer-9.0-20261116-2a9b3fe-iris"
  RPC = "e05473c76faa4cc757703b9ba5e521068613e1f0"
  OTHER = "a" * 40

  def fixture(name) = JSON.parse(File.read(File.join(DIR, name)))

  # The real ydb harness record, as the train writes it: the rpms-rpc ref it ran and the tag the commit takes.
  def train_harness
    h = fixture("#{YDB}-harness.json")
    h["harness"].merge!("rpms_rpc_ref" => "main", "rpms_rpc_tag" => YDB)
    h
  end

  # The real ydb per-RPC record, as v2: the release block and the contract verdict bin/rpms_rpc_record.rb adds.
  def train_record(pass: true, broken: [])
    r = fixture("#{YDB}-rpms-rpc-live.json")
    r.merge("record" => "rpms-rpc-live.v2",
            "release" => { "tag" => YDB, "engine" => "yottadb", "rpms_rpc" => { "commit" => RPC, "ref" => "main", "tag" => YDB } },
            "contract" => { "source" => "lib/rpms_rpc/required_rpcs.json", "schema" => "rpms-rpc-contract.v1", "rpcs" => 288, "pass" => pass, "broken" => broken })
  end

  def decide(harness: train_harness, record: train_record, on_main: true, existing: nil)
    T.decide(tag: YDB, harness: harness, record: record, on_main: on_main, existing: existing)
  end

  def test_only_published_build_releases_carrying_both_records_are_candidates_oldest_first
    releases = fixture("releases.json")
    assert_equal %w[bcer-9.0-20261107-312e774-ydb bcer-9.0-20261113-3f5487a-ydb bcer-9.0-20261113-3f5487a-iris] + [ YDB, IRIS ], T.candidates(releases).map { |r| r["tag_name"] }
    refute_includes T.candidates(releases).map { |r| r["tag_name"] }, "bcer-9.0-20261111-312e774-ydb", "its 20261111 re-tag carries no harness record"

    draft = releases.map { |r| r["tag_name"] == YDB ? r.merge("draft" => true) : r }
    refute_includes T.candidates(draft).map { |r| r["tag_name"] }, YDB
    renamed = releases.map { |r| r["tag_name"] == YDB ? r.merge("tag_name" => "bcer-9.0-ydb") : r }
    refute_includes T.candidates(renamed).map { |r| r["tag_name"] }, "bcer-9.0-ydb"
  end

  # Every release published so far has the record from before the train: it names a commit, and no tag to take.
  def test_a_published_pre_train_record_is_skipped_not_refused
    [ YDB, IRIS ].each do |tag|
      d = T.decide(tag: tag, harness: fixture("#{tag}-harness.json"), record: fixture("#{YDB}-rpms-rpc-live.json"), on_main: true)
      assert_equal "skip", d[:action], tag
      assert_equal RPC, d[:commit]
      assert_match(/before the train: names rpms-rpc e05473c76faa but no tag to take/, d[:why])
    end
  end

  def test_a_train_record_whose_contract_passed_is_tagged_with_the_release_name
    assert_equal({ action: "tag", tag: YDB, commit: RPC, why: nil }, decide)
  end

  def test_a_tag_already_at_the_commit_gets_its_release_and_a_tag_elsewhere_is_never_moved
    assert_equal "release", decide(existing: RPC)[:action]
    d = decide(existing: OTHER)
    assert_equal "refuse", d[:action]
    assert_match(/already names #{OTHER}, not #{RPC}; a tag is never moved/, d[:why])
  end

  def test_a_contract_that_did_not_pass_is_refused_naming_what_broke
    d = decide(record: train_record(pass: false, broken: [ { "rpc" => "ORWPT SELECT", "why" => "not registered on this build" } ]))
    assert_equal "refuse", d[:action]
    assert_match(/the contract did not pass: ORWPT SELECT \(not registered on this build\)/, d[:why])
    assert_equal "refuse", decide(record: train_record(pass: true, broken: [ { "rpc" => "X", "why" => "y" } ]))[:action], "pass with a broken RPC"
    assert_equal "refuse", decide(record: train_record(pass: false))[:action], "not pass, nothing listed"
  end

  def test_a_record_that_cannot_say_whether_the_contract_passed_is_refused
    { "the published v1 record" => fixture("#{YDB}-rpms-rpc-live.json"),
      "no record" => nil,
      "a record without its contract" => train_record.except("contract") }.each do |what, record|
      assert_equal "refuse", decide(record: record)[:action], what
    end
    assert_match(/is nil, not rpms-rpc-live.v2/, decide(record: fixture("#{YDB}-rpms-rpc-live.json"))[:why])
  end

  def test_records_that_disagree_with_the_release_or_each_other_are_refused
    wrong_release = train_harness.merge("release" => IRIS)
    wrong_tag = train_harness.tap { |h| h["harness"]["rpms_rpc_tag"] = IRIS }
    short = train_harness.tap { |h| h["harness"]["rpms_rpc_commit"] = "e05473c" }
    other_record = train_record.tap { |r| r["release"]["rpms_rpc"]["commit"] = OTHER }
    record_for_iris = train_record.tap { |r| r["release"]["tag"] = IRIS }
    {
      /names release "#{IRIS}", not #{YDB}/ => decide(harness: wrong_release),
      /takes tag "#{IRIS}", not #{YDB}/ => decide(harness: wrong_tag),
      /names rpms-rpc commit "e05473c", not a full commit/ => decide(harness: short),
      /names rpms-rpc "#{OTHER}", the harness record #{RPC}/ => decide(record: other_record),
      /rpms-rpc-live.json names release "#{IRIS}"/ => decide(record: record_for_iris),
      /is not on main/ => decide(on_main: false),
      /is not a harness record/ => decide(harness: { "release" => YDB })
    }.each do |why, d|
      assert_equal "refuse", d[:action], why.source
      assert_match why, d[:why]
    end
  end

  def test_the_summary_lists_what_to_tag_for_the_workflow_matrix
    s = T.summary([ decide, decide(existing: RPC), decide(on_main: false),
                    T.decide(tag: IRIS, harness: fixture("#{IRIS}-harness.json"), record: nil, on_main: true) ])
    assert_equal [ { "tag" => YDB, "commit" => RPC, "action" => "tag" }, { "tag" => YDB, "commit" => RPC, "action" => "release" } ], s["todo"]
    assert_equal [ IRIS ], s["skipped"].map { |d| d["tag"] }
    assert_equal [ YDB ], s["refused"].map { |d| d["tag"] }
  end
end
