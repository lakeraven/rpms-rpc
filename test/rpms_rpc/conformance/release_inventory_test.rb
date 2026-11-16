# frozen_string_literal: true

require "minitest/autorun"
require "digest"
require "json"
require "tmpdir"
require "yaml"
require "rpms_rpc/conformance/release_inventory"
require_relative "../pinned_rpcs_test_helper"

# ReleaseInventory (rpms-rpc#222, #394, #406, #724) on a release's own assets (the committed fixture,
# cut from a real release by tools/fixture_inventory.rb): each test copies it and changes the one thing
# it is about.
class RpmsRpc::Conformance::ReleaseInventoryTest < Minitest::Test
  Lock = RpmsRpc::Conformance::ReleaseInventory
  P = PinnedRpcsTestHelper
  TAG = P::TAG
  PROVENANCE = JSON.parse(File.read(File.join(P::INVENTORY_DIR, "#{TAG}-INVENTORY-PROVENANCE.json")))
  RPCS = PROVENANCE.dig("dumps", "rpcs", "records")
  BUILD_COMMIT = "e7923a473fa27060c40978f4d46be3de391c97ae"

  def asset(dir, suffix) = File.join(dir, "#{TAG}-#{suffix}")

  def with_inventory
    Dir.mktmpdir { |root| yield P.copy_pinned_inventory(root), root }
  end

  # Rewrite one JSON asset through BLOCK, keeping the sidecar honest when it covers the asset, so
  # the change reaches the check that is under test.
  def edit_json(dir, suffix, reseal: false)
    path = asset(dir, suffix)
    doc = JSON.parse(File.read(path, encoding: "UTF-8"))
    yield doc
    File.write(path, JSON.pretty_generate(doc))
    reseal_sidecar(dir, suffix) if reseal
  end

  def reseal_sidecar(dir, suffix)
    sidecar = asset(dir, Lock::SIDECAR_SUFFIX)
    name = "#{TAG}-#{suffix}"
    lines = File.readlines(sidecar, chomp: true).map do |l|
      l.end_with?(name) ? "#{Digest::SHA256.file(File.join(dir, name)).hexdigest}  #{name}" : l
    end
    File.write(sidecar, "#{lines.join("\n")}\n")
  end

  def refusal(dir) = assert_raises(Lock::Error) { Lock.verify_dir(TAG, dir) }.message

  def test_verify_dir_accepts_the_pinned_release
    with_inventory do |dir|
      inv = Lock.verify_dir(TAG, dir)
      assert_equal %w[rpcs.json packages_9_4.txt contexts_19_05.txt INVENTORY-PROVENANCE.json], Lock::ASSET_SUFFIXES
      assets = (Lock::ASSET_SUFFIXES + [ Lock::BUILD_RECORD_SUFFIX ]).to_h { |x| [ "#{TAG}-#{x}", Lock.sha256(asset(dir, x)) ] }
      assert_equal assets.sort.to_h, inv.shas.sort.to_h
      assert_equal "yottadb", inv.engine
      assert_equal BUILD_COMMIT, inv.build_commit
      assert_equal "ghcr.io/lakeraven/rpms-ydb@#{PROVENANCE['artifact_sha256']}", inv.image_ref
      assert_equal PROVENANCE.dig("rpc_reach", "classes"), inv.surface.reach_counts
      assert_equal RPCS, inv.surface.rpcs.size
      src = inv.to_source
      assert_equal [ TAG, assets["#{TAG}-rpcs.json"], "rpcs.v1" ], src.values_at("tag", "rpcs_json_sha256", "rpcs_json_schema")
      # The raw files the document was projected from, as it names them: the sidecar's bytes.
      sidecar = File.readlines(asset(dir, Lock::SIDECAR_SUFFIX), chomp: true).to_h { |l| l.split(/\s+\*?/, 2).reverse }
      %w[broker_8994 rpc_reach rpc_signatures].each do |raw|
        assert_equal sidecar["#{TAG}-#{raw}.txt"], src["#{raw}_sha256"], raw
      end
    end
  end

  # --- rpcs.json against the build it claims to describe (#406) ----------------------------------

  def test_verify_dir_rejects_a_release_without_rpcs_json
    with_inventory do |dir|
      File.delete(asset(dir, "rpcs.json"))
      assert_match(/missing or empty asset #{TAG}-rpcs.json/, refusal(dir))
    end
  end

  def test_verify_dir_rejects_rpcs_json_projected_from_other_bytes
    with_inventory do |dir|
      edit_json(dir, "rpcs.json") { |d| d["inputs"]["rpc_reach.txt"] = "0" * 64 }
      assert_match(/projected from rpc_reach.txt "0{64}", not the sidecar's/, refusal(dir))
    end
  end

  def test_verify_dir_rejects_rpcs_json_for_another_build
    with_inventory do |dir|
      edit_json(dir, "rpcs.json") { |d| d["commit"] = "f" * 40 }
      assert_match(/commit "f{40}" is not the build record's/, refusal(dir))
    end
    with_inventory do |dir|
      edit_json(dir, "rpcs.json") { |d| d["engine"] = "iris" }
      assert_match(/engine "iris" is not the provenance's "yottadb"/, refusal(dir))
    end
    with_inventory do |dir|
      edit_json(dir, "rpcs.json") { |d| d["tag"] = "bcer-9.0-20990101-0000000-ydb" }
      assert_match(/names tag "bcer-9.0-20990101-0000000-ydb", not #{TAG}/, refusal(dir))
    end
  end

  def test_verify_dir_rejects_a_truncated_rpcs_json
    with_inventory do |dir|
      edit_json(dir, "rpcs.json") { |d| d["rpcs"].pop }
      assert_match(/lists #{RPCS - 1} RPCs, the provenance counted #{RPCS} \(truncated\?\)/, refusal(dir))
    end
  end

  def test_verify_dir_rejects_reach_classes_the_provenance_does_not_count
    with_inventory do |dir|
      edit_json(dir, "rpcs.json") { |d| d["rpcs"].find { |r| r.dig("reach", "class") == "no-context" }["reach"]["class"] = "client-callable" }
      assert_match(/reach classes .* != provenance/, refusal(dir))
    end
  end

  def test_verify_dir_rejects_an_unknown_reach_class
    with_inventory do |dir|
      edit_json(dir, "rpcs.json") { |d| d["rpcs"].find { |r| r["name"] == "ORWPT SELECT" }["reach"]["class"] = "maybe-callable" }
      assert_match(/"ORWPT SELECT" has reach "maybe-callable"/, refusal(dir))
    end
  end

  # --- the other faces and the provenance ----------------------------------------------------

  # rpms-rpc#416: the contexts face is a pinned asset, held to the sidecar like the others.
  def test_verify_dir_rejects_a_release_without_the_contexts_face
    with_inventory do |dir|
      File.delete(asset(dir, "contexts_19_05.txt"))
      assert_match(/missing or empty asset #{TAG}-contexts_19_05.txt/, refusal(dir))
    end
  end

  def test_verify_dir_rejects_a_tampered_face_the_sidecar_covers
    with_inventory do |dir|
      File.write(asset(dir, "contexts_19_05.txt"), File.read(asset(dir, "contexts_19_05.txt")).sub("OR CPRS GUI CHART", "OR CPRS GUI CHARX"))
      assert_match(/sha256 mismatch for #{TAG}-contexts_19_05.txt/, refusal(dir))
    end
    with_inventory do |dir|
      File.open(asset(dir, "packages_9_4.txt"), "a") { |f| f.puts "ZZ^LATE PACKAGE^1.0" }
      assert_match(/sha256 mismatch for #{TAG}-packages_9_4.txt/, refusal(dir))
    end
  end

  def test_the_verified_surface_reads_the_contexts_face
    with_inventory do |dir|
      surface = Lock.verify_dir(TAG, dir).surface
      assert surface.contexts?
      assert_nil surface.context_refusal("OR CPRS GUI CHART", "ORWPT SELECT")
      assert_nil surface.context_refusal("BMCRPC", "BMC ADD REFERRAL")
      assert_equal "OR CPRS GUI CHART does not serve BMC ADD REFERRAL on #{TAG}", surface.context_refusal("OR CPRS GUI CHART", "BMC ADD REFERRAL")
    end
  end

  def test_verify_dir_rejects_a_provenance_without_the_reach_face
    with_inventory do |dir|
      edit_json(dir, "INVENTORY-PROVENANCE.json", reseal: true) { |d| d.delete("rpc_reach") }
      message = refusal(dir)
      assert_match(/no rpc_reach face/, message)
    end
  end

  def test_verify_dir_rejects_a_provenance_face_sha_rpcs_json_was_not_projected_from
    with_inventory do |dir|
      edit_json(dir, "INVENTORY-PROVENANCE.json", reseal: true) { |d| d["rpc_signatures"]["sha256"] = "0" * 64 }
      assert_match(/provenance rpc_signatures.sha256 "0{64}" is not #{TAG}-rpcs.json's rpc_signatures.txt input/, refusal(dir))
    end
  end

  def test_verify_dir_rejects_an_image_that_is_not_the_artifact
    with_inventory do |dir|
      edit_json(dir, "INVENTORY-PROVENANCE.json", reseal: true) { |d| d["image"]["digest"] = "sha256:0ther" }
      assert_match(/image.digest/, refusal(dir))
    end
  end

  def test_verify_dir_rejects_an_unbound_capture_or_one_for_another_tag
    with_inventory do |dir|
      edit_json(dir, "INVENTORY-PROVENANCE.json", reseal: true) { |d| d["artifact_bound"] = false }
      assert_match(/not artifact_bound/, refusal(dir))
    end
    with_inventory do |dir|
      edit_json(dir, "INVENTORY-PROVENANCE.json", reseal: true) { |d| d["release_tag"] = "bcer-9.0-other-ydb" }
      assert_match(/release_tag/, refusal(dir))
    end
  end

  def test_verify_dir_rejects_a_build_record_for_another_commit_or_release
    with_inventory do |dir|
      edit_json(dir, "PROVENANCE.json") { |d| d["rpms_ops_commit"] = "f" * 40 }
      assert_match(/build record commit/, refusal(dir))
    end
    with_inventory do |dir|
      edit_json(dir, "PROVENANCE.json") { |d| d["release"] = "bcer-9.0-other-ydb" }
      assert_match(/build record release/, refusal(dir))
    end
  end

  def test_verify_dir_rejects_a_tag_that_names_no_build
    with_inventory do |dir|
      assert_match(/names no build/, assert_raises(Lock::Error) { Lock.verify_dir("bcer-9.0-ydb", dir) }.message)
    end
  end

  def test_parse_tag
    assert_equal({ rpms_version: "bcer-9.0", date: "20260930", short_commit: "8c88e47", engine: "yottadb" },
                 Lock.parse_tag("bcer-9.0-20260930-8c88e47-ydb"))
    assert_equal "iris", Lock.parse_tag("bcer-9.0-20260909-576682d-iris")[:engine]
    assert_nil Lock.parse_tag("bcer-9.0-iris")
  end

  # --- which release: the latest published -ydb release that carries its inventory (#724) -------

  def release(tag, published_at, draft: false, prerelease: false, assets: Lock.asset_names(tag))
    { "tag_name" => tag, "published_at" => published_at, "draft" => draft, "prerelease" => prerelease,
      "assets" => assets.map { |n| { "name" => n } } }
  end

  def test_pick_latest_takes_the_newest_published_ydb_release_with_its_inventory
    releases = [
      release("bcer-9.0-20261113-3f5487a-ydb", "2026-11-13T22:38:13Z"),
      release("bcer-9.0-20261116-2a9b3fe-iris", "2026-11-16T05:57:15Z"),
      release("bcer-9.0-20261116-2a9b3fe-ydb", "2026-11-16T03:59:25Z"),
      release("bcer-9.0-20261117-1111111-ydb", "2026-11-17T00:00:00Z", draft: true),
      release("bcer-9.0-20261118-2222222-ydb", "2026-11-18T00:00:00Z", prerelease: true),
      release("bcer-9.0-20261111-312e774-ydb", "2026-11-19T00:00:00Z", assets: [ "bcer-9.0-20261111-312e774-ydb-PROVENANCE.json" ]),
      release("v1.0.0", "2026-11-20T00:00:00Z")
    ]
    assert_equal "bcer-9.0-20261116-2a9b3fe-ydb", Lock.pick_latest(releases)[:tag]
  end

  def test_pick_latest_refuses_when_no_release_carries_the_inventory
    err = assert_raises(Lock::Error) { Lock.pick_latest([ release("bcer-9.0-20261116-2a9b3fe-iris", "2026-11-16T05:57:15Z") ]) }
    assert_match(/no published bcer-\*-ydb release on lakeraven\/openrpms carries the inventory/, err.message)
  end

  def test_the_cache_root_is_tmp_openrpms_unless_named
    assert_equal File.join(P::ROOT, "tmp/openrpms"), Lock.cache_root({})
    assert_equal File.join(P::ROOT, "tmp/openrpms"), Lock.cache_root({ "OPENRPMS_INVENTORIES" => " " })
    assert_equal "/x/y", Lock.cache_root({ "OPENRPMS_INVENTORIES" => "/x/y" })
  end

  # current.json records which release a checkout tests against; `current` reads it back offline.
  def test_record_current_then_current_reads_the_verified_release_back
    with_inventory do |dir, root|
      inv = Lock.verify_dir(TAG, dir)
      doc = Lock.record_current!(inv, root: root, chosen_by: "latest")
      assert_equal [ TAG, "latest", inv.image_ref, BUILD_COMMIT, RPCS ], doc.values_at("tag", "chosen_by", "image", "build_commit", "rpcs")
      assert_equal doc.except("resolved_at"), JSON.parse(File.read(File.join(root, "current.json"))).except("resolved_at")
      assert_equal TAG, Lock.current(root: root).tag
    end
  end

  def test_current_refuses_without_a_record_or_with_files_that_no_longer_verify
    Dir.mktmpdir do |root|
      assert_match(/no openrpms release fetched into .* rake openrpms:fetch/, assert_raises(Lock::Error) { Lock.current(root: root) }.message)
    end
    with_inventory do |dir, root|
      Lock.record_current!(Lock.verify_dir(TAG, dir), root: root, chosen_by: "latest")
      File.delete(asset(dir, "rpcs.json"))
      assert_match(/missing or empty asset/, assert_raises(Lock::Error) { Lock.current(root: root) }.message)
    end
  end

  # A downloaded dir that already verifies is used as it is: no network.
  def test_fetch_keeps_a_cached_release_that_verifies
    with_inventory do |_dir, root|
      assert_equal TAG, Lock.fetch(TAG, root: root, repo: "nobody/nothing").tag
    end
  end

  def test_fetch_refuses_a_tag_that_names_no_build
    assert_match(/names no build/, assert_raises(Lock::Error) { Lock.fetch("latest") }.message)
  end
end
