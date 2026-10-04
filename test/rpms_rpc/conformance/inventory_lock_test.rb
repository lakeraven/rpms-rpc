# frozen_string_literal: true

require "minitest/autorun"
require "digest"
require "json"
require "tmpdir"
require "yaml"
require "rpms_rpc/conformance/inventory_lock"
require "rpms_rpc/conformance/ingest"

class RpmsRpc::Conformance::InventoryLockTest < Minitest::Test
  Lock = RpmsRpc::Conformance::InventoryLock
  TAG = "bcer-9.0-20260903-abc1234-ydb"

  BUILD_COMMIT = "abc1234#{'0' * 33}"

  # #8994 0-nodes as rpms-ops dumps them: NAME^TAG^ROUTINE^RETURN VALUE TYPE^AVAILABILITY^INACTIVE^...
  REGISTRY = <<~TXT
    XWB IM HERE^IMHERE^XWBIMHER^1^P
    ORWPT SELECT^SELECT^ORWPT^1
    BEHOVM2 VUNITS^VUNITS^BEHOVM2^1^^^^1
    XUS CCOW VAULT PARAM^CCOWPC^XUSRB4^2^R^3^^0
  TXT
  PACKAGES = "XWB^RPC BROKER^1.1\nOR^ORDER ENTRY/RESULTS REPORTING^3.0\n"

  # Write the four rpms-ops assets for TAG into DIR (what bin/release_inventory.sh produces).
  def write_inventory(dir, tag: TAG, registry: REGISTRY, bound: true, release_tag: nil, records: nil, engine: "yottadb",
                      build_commit: BUILD_COMMIT, build_release: nil)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "#{tag}-broker_8994.txt"), registry)
    File.write(File.join(dir, "#{tag}-packages_9_4.txt"), PACKAGES)
    prov = {
      "schema_version" => 3, "label" => "inventory-#{tag}", "release_tag" => release_tag || tag,
      "artifact_sha256" => "sha256:deadbeef", "engine" => engine, "m_backend" => engine,
      "artifact_bound" => bound, "transport" => "local", "container" => "rpms-ydb",
      "captured_at" => "2026-09-03T12:00:00Z", "tool_git_sha" => "0123456789abcdef",
      "dumps" => { "packages" => { "records" => 2 }, "builds" => { "records" => 9 },
                   "rpcs" => { "records" => records || registry.lines.count } }
    }
    File.write(File.join(dir, "#{tag}-INVENTORY-PROVENANCE.json"), JSON.pretty_generate(prov))
    sidecar = Lock::ASSET_SUFFIXES.map do |s|
      name = "#{tag}-#{s}"
      "#{Digest::SHA256.file(File.join(dir, name)).hexdigest}  #{name}"
    end
    File.write(File.join(dir, "#{tag}-INVENTORY.sha256"), "#{sidecar.join("\n")}\n")
    # The build record rpms-ops attaches beside the inventory (not covered by the sidecar).
    build = { "release" => build_release || tag, "rpms_ops_commit" => build_commit }
    File.write(File.join(dir, "#{tag}-PROVENANCE.json"), JSON.pretty_generate(build))
    dir
  end

  def test_verify_dir_accepts_a_bound_complete_inventory
    Dir.mktmpdir do |dir|
      inv = Lock.verify_dir(TAG, write_inventory(dir))
      assert_equal "yottadb", inv.engine
      assert_equal 3, Lock::ASSET_SUFFIXES.size
      assert_equal Digest::SHA256.hexdigest(REGISTRY), inv.shas["#{TAG}-broker_8994.txt"]
      assert_equal TAG, inv.to_source["tag"]
      assert_equal "sha256:deadbeef", inv.to_source["artifact_sha256"]
      assert_equal "bcer-9.0", inv.rpms_version
      assert_equal BUILD_COMMIT, inv.build_commit
      assert_equal BUILD_COMMIT, inv.to_source["build_commit"]
      assert_equal "0123456789abcdef", inv.to_source["inventory_tool_commit"]
    end
  end

  def test_verify_dir_rejects_a_build_record_for_another_commit
    Dir.mktmpdir do |dir|
      e = assert_raises(Lock::Error) { Lock.verify_dir(TAG, write_inventory(dir, build_commit: "f" * 40)) }
      assert_match(/build record commit/, e.message)
    end
  end

  def test_verify_dir_rejects_a_build_record_for_another_release
    Dir.mktmpdir do |dir|
      e = assert_raises(Lock::Error) { Lock.verify_dir(TAG, write_inventory(dir, build_release: "bcer-9.0-other-ydb")) }
      assert_match(/build record release/, e.message)
    end
  end

  def test_verify_dir_rejects_a_tag_that_names_no_build
    Dir.mktmpdir do |dir|
      e = assert_raises(Lock::Error) { Lock.verify_dir("bcer-9.0-iris", write_inventory(dir, tag: "bcer-9.0-iris")) }
      assert_match(/names no build/, e.message)
    end
  end

  def test_parse_tag
    assert_equal({ rpms_version: "bcer-9.0", date: "20260930", short_commit: "8c88e47", engine: "yottadb" },
                 Lock.parse_tag("bcer-9.0-20260930-8c88e47-ydb"))
    assert_equal "iris", Lock.parse_tag("bcer-9.0-20260909-576682d-iris")[:engine]
    assert_nil Lock.parse_tag("bcer-9.0-iris")
  end

  def test_verify_dir_rejects_a_tampered_registry
    Dir.mktmpdir do |dir|
      write_inventory(dir)
      File.open(File.join(dir, "#{TAG}-broker_8994.txt"), "a") { |f| f.puts "EVIL RPC^X^Y" }
      e = assert_raises(Lock::Error) { Lock.verify_dir(TAG, dir) }
      assert_match(/sha256 mismatch/, e.message)
    end
  end

  def test_verify_dir_rejects_an_unbound_capture
    Dir.mktmpdir do |dir|
      e = assert_raises(Lock::Error) { Lock.verify_dir(TAG, write_inventory(dir, bound: false)) }
      assert_match(/not artifact_bound/, e.message)
    end
  end

  def test_verify_dir_rejects_a_provenance_for_another_tag
    Dir.mktmpdir do |dir|
      e = assert_raises(Lock::Error) { Lock.verify_dir(TAG, write_inventory(dir, release_tag: "bcer-9.0-other-ydb")) }
      assert_match(/release_tag/, e.message)
    end
  end

  def test_verify_dir_rejects_a_truncated_registry
    Dir.mktmpdir do |dir|
      e = assert_raises(Lock::Error) { Lock.verify_dir(TAG, write_inventory(dir, records: 5265)) }
      assert_match(/truncated/, e.message)
    end
  end

  def test_verify_dir_rejects_a_missing_asset
    Dir.mktmpdir do |dir|
      write_inventory(dir)
      File.delete(File.join(dir, "#{TAG}-packages_9_4.txt"))
      e = assert_raises(Lock::Error) { Lock.verify_dir(TAG, dir) }
      assert_match(/missing or empty asset/, e.message)
    end
  end

  def test_pin_ingest_and_check_round_trip
    Dir.mktmpdir do |root|
      inv_dir = write_inventory(File.join(root, "inventories", TAG))
      fp_dir = File.join(root, "fingerprints")
      lock_path = File.join(fp_dir, Lock::DEFAULT_PATH)
      inv = Lock.verify_dir(TAG, inv_dir)

      r = RpmsRpc::Conformance::Ingest.run(
        dump: inv.broker_dump, packages: inv.packages_dump, env: "references/#{TAG}", fingerprints_dir: fp_dir,
        backend: RpmsRpc::Conformance::Ingest::BACKEND_FOR_ENGINE.fetch(inv.engine),
        captured_at: "2026-09-03", release: TAG, dat_sha: inv.provenance["artifact_sha256"], inventory: inv.to_source
      )
      assert_equal 4, r[:rpcs]
      assert_equal 2, r[:packages]

      lock = Lock.load(lock_path)
      lock.pin!(inv, fingerprint: "references/#{TAG}", rpcs: r[:rpcs], packages: r[:packages])
      lock.save

      fp = YAML.safe_load_file(r[:path])
      assert_equal "yottadb_rpms", fp["backend"]
      assert_equal "rpms", fp["lineage"]
      assert_equal TAG, fp["release"]
      assert_equal Digest::SHA256.hexdigest(REGISTRY), fp.dig("source", "inventory", "broker_8994_sha256")
      assert_equal({ "tag" => "VUNITS", "routine" => "BEHOVM2", "return_type" => "1" }, fp["rpcs"]["BEHOVM2 VUNITS"])
      assert_equal({ "tag" => "IMHERE", "routine" => "XWBIMHER", "return_type" => "1", "availability" => "P" },
                   fp["rpcs"]["XWB IM HERE"])
      assert_equal "3", fp["rpcs"]["XUS CCOW VAULT PARAM"]["inactive"]
      assert_equal "3.0", fp["packages"]["ORDER ENTRY/RESULTS REPORTING"].to_s

      reloaded = Lock.load(lock_path)
      assert_equal 4, reloaded[TAG]["rpcs"]
      assert_equal "bcer-9.0", reloaded[TAG]["rpms_version"]
      assert_equal BUILD_COMMIT, reloaded[TAG]["build_commit"]
      assert_equal "sha256:deadbeef", reloaded[TAG]["artifact_sha256"]
      assert_empty reloaded.check(fingerprints_dir: fp_dir, inventories_dir: File.join(root, "inventories"))
      assert_equal 4, reloaded.pinned_rpcs(fingerprints_dir: fp_dir)[TAG].size

      # A hand-edited fingerprint no longer matches its pin.
      File.write(r[:path], File.read(r[:path]).sub("BEHOVM2 VUNITS", "BEHOVM2 VUNITZ"))
      problems = reloaded.check(fingerprints_dir: fp_dir)
      assert_empty problems.grep(/sha256/), "renaming an RPC does not change the pinned dump sha"
      # ...but against the committed signature the fingerprint no longer re-derives.
      problems = reloaded.check(fingerprints_dir: fp_dir, inventories_dir: File.join(root, "inventories"))
      refute_empty problems.grep(/fingerprint rpcs differ from the pinned dump \(BEHOVM2 VUNITS/)
      # ...but deleting one changes the count the lock recorded.
      File.write(r[:path], File.read(r[:path]).sub(/^  ORWPT SELECT:\n(    .*\n)+/, ""))
      problems = reloaded.check(fingerprints_dir: fp_dir)
      refute_empty problems.grep(/3 RPCs, lock says 4/)

      # A local inventory dir whose bytes drifted from the lock is reported too.
      File.open(File.join(inv_dir, "#{TAG}-broker_8994.txt"), "a") { |f| f.puts "LATE RPC^X^Y" }
      problems = reloaded.check(fingerprints_dir: fp_dir, inventories_dir: File.join(root, "inventories"))
      refute_empty problems.grep(/local inventory dir fails verification/)
    end
  end

  def test_check_reports_a_missing_fingerprint
    Dir.mktmpdir do |root|
      inv = Lock.verify_dir(TAG, write_inventory(File.join(root, "inv")))
      lock = Lock.load(File.join(root, "lock.yml"))
      lock.pin!(inv, fingerprint: "references/#{TAG}", rpcs: 4, packages: 2)
      problems = lock.check(fingerprints_dir: File.join(root, "fingerprints"))
      assert_equal 1, problems.size
      assert_match(/is missing/, problems.first)
    end
  end

  def test_check_requires_the_committed_signature_when_asked
    Dir.mktmpdir do |root|
      inv = Lock.verify_dir(TAG, write_inventory(File.join(root, "inv")))
      lock = Lock.load(File.join(root, "lock.yml"))
      lock.pin!(inv, fingerprint: "references/#{TAG}", rpcs: 4, packages: 2)
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
