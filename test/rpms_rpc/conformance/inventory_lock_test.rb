# frozen_string_literal: true

require "minitest/autorun"
require "digest"
require "json"
require "tmpdir"
require "yaml"
require "rpms_rpc/conformance/inventory_lock"
require "rpms_rpc/conformance/ingest"
require_relative "../pinned_rpcs_test_helper"

# InventoryLock (rpms-rpc#222, #394, #406) on the pinned release's own assets: each test copies
# data/inventories/<tag>/ as rpms-ops published it and changes the one thing it is about.
class RpmsRpc::Conformance::InventoryLockTest < Minitest::Test
  Lock = RpmsRpc::Conformance::InventoryLock
  P = PinnedRpcsTestHelper
  TAG = P::TAG
  ENTRY = P::LOCK[TAG]

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
      assert_equal ENTRY["assets"], inv.shas.sort.to_h
      assert_equal ENTRY["engine"], inv.engine
      assert_equal ENTRY["build_commit"], inv.build_commit
      assert_equal ENTRY["image"], inv.image_ref
      assert_equal ENTRY["reach_classes"], inv.surface.reach_counts
      assert_equal ENTRY["rpcs"], inv.surface.rpcs.size
      src = inv.to_source
      assert_equal [ TAG, ENTRY["assets"]["#{TAG}-rpcs.json"], "rpcs.v1" ], src.values_at("tag", "rpcs_json_sha256", "rpcs_json_schema")
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
      assert_match(/lists #{ENTRY['rpcs'] - 1} RPCs, the provenance counted #{ENTRY['rpcs']} \(truncated\?\)/, refusal(dir))
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

  # --- pin, ingest, check ----------------------------------------------------------------------

  def test_pin_ingest_and_check_round_trip
    with_inventory do |inv_dir, root|
      inventories = root
      fp_dir = File.join(root, "fingerprints")
      inv = Lock.verify_dir(TAG, inv_dir)

      r = RpmsRpc::Conformance::Ingest.run(
        surface: inv.surface, packages: inv.packages_dump, env: "references/#{TAG}", fingerprints_dir: fp_dir,
        backend: RpmsRpc::Conformance::Ingest::BACKEND_FOR_ENGINE.fetch(inv.engine),
        captured_at: inv.provenance["captured_at"].to_s[0, 10], release: TAG, dat_sha: inv.provenance["artifact_sha256"],
        note: "rpms-ops release inventory #{TAG} (lakeraven/rpms-ops), pinned by conformance:pin", inventory: inv.to_source
      )
      assert_equal [ ENTRY["rpcs"], ENTRY["packages"] ], [ r[:rpcs], r[:packages] ]

      # The fingerprint rake conformance:pin committed is what the same steps derive here.
      committed = File.join(P::ROOT, "data/fingerprints", "#{ENTRY['fingerprint']}.yml")
      assert_equal File.read(committed), File.read(r[:path])

      fp = YAML.safe_load_file(r[:path])
      assert_equal({ "tag" => "SELECT", "routine" => "ORWPT", "return_type" => "1" }, fp["rpcs"]["ORWPT SELECT"])
      assert_equal "3", fp["rpcs"]["XUS CCOW VAULT PARAM"]["inactive"]

      lock = Lock.load(File.join(fp_dir, Lock::DEFAULT_PATH))
      lock.pin!(inv, fingerprint: "references/#{TAG}", rpcs: r[:rpcs], packages: r[:packages])
      lock.save
      reloaded = Lock.load(lock.path)
      assert_equal ENTRY, reloaded[TAG]
      assert_empty reloaded.check(fingerprints_dir: fp_dir, inventories_dir: inventories)
      assert_equal ENTRY["rpcs"], reloaded.surfaces(inventories_dir: inventories)[TAG].names.size

      # A hand-edited fingerprint no longer re-derives from the committed rpcs.json...
      File.write(r[:path], File.read(r[:path]).sub("ORWPT SELECT:", "ORWPT SELECX:"))
      problems = reloaded.check(fingerprints_dir: fp_dir, inventories_dir: inventories)
      refute_empty problems.grep(/fingerprint rpcs differ from the pinned rpcs.json \(ORWPT SELECT/)
      # ...and deleting one changes the count the lock recorded.
      File.write(r[:path], File.read(r[:path]).sub(/^  ORWPT SELECX:\n(    .*\n)+/, ""))
      refute_empty reloaded.check(fingerprints_dir: fp_dir).grep(/#{ENTRY['rpcs'] - 1} RPCs, lock says #{ENTRY['rpcs']}/)

      # A committed rpcs.json whose bytes drifted from the lock is reported, though it still verifies.
      edit_json(inv_dir, "rpcs.json") { |d| d["rpcs"].find { |x| x["name"] == "ORWPT SELECT" }["entry_point"]["routine"] = "ORWPX" }
      problems = reloaded.check(fingerprints_dir: fp_dir, inventories_dir: inventories)
      refute_empty problems.grep(/local asset #{TAG}-rpcs.json sha256 \h+ != lock/)
    end
  end

  def test_check_reports_a_missing_fingerprint
    with_inventory do |dir, root|
      lock = Lock.load(File.join(root, "lock.yml"))
      lock.pin!(Lock.verify_dir(TAG, dir), fingerprint: "references/#{TAG}", rpcs: ENTRY["rpcs"], packages: ENTRY["packages"])
      problems = lock.check(fingerprints_dir: File.join(root, "fingerprints"))
      assert_equal 1, problems.size
      assert_match(/is missing/, problems.first)
    end
  end

  def test_check_requires_the_committed_signature_when_asked
    with_inventory do |dir, root|
      lock = Lock.load(File.join(root, "lock.yml"))
      lock.pin!(Lock.verify_dir(TAG, dir), fingerprint: "references/#{TAG}", rpcs: ENTRY["rpcs"], packages: ENTRY["packages"])
      problems = lock.check(fingerprints_dir: root, inventories_dir: File.join(root, "absent"), require_inventories: true)
      refute_empty problems.grep(/signature is not committed/)
    end
  end

  def test_an_empty_lock_checks_clean
    Dir.mktmpdir do |root|
      assert_empty Lock.load(File.join(root, "absent.yml")).check(fingerprints_dir: root)
    end
  end
end
