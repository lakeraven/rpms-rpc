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
  # The reach face, same RPCs in the same order: NAME^REACH^ROUTINE_PRESENT^TAG_PRESENT^CONTEXTS^EXEMPT_ON
  REACH = <<~TXT
    XWB IM HERE^broker-exempt^1^1^^xwb
    ORWPT SELECT^client-callable^1^1^OR CPRS GUI CHART;CIAV VUECENTRIC^
    BEHOVM2 VUNITS^client-callable^1^1^CIAV VUECENTRIC^
    XUS CCOW VAULT PARAM^no-context^1^1^^
  TXT
  REACH_CLASSES = { "broker-exempt" => 1, "client-callable" => 2, "no-context" => 1 }.freeze
  # ZRPCCAT's walk (tab-separated), ending in its EXPLICIT SUCCESS line.
  SIGNATURES = [
    "RPC\t1\tXWB IM HERE\tIMHERE\tXWBIMHER\t1\tP\t\t\t\t\t\t\t1\t1\tRESULT",
    "DESC\t1\tReturns 1 when the broker is alive.",
    "RPC\t2\tORWPT SELECT\tSELECT\tORWPT\t1\t\t\t\t\t\t\t\t1\t1\tY,DFN",
    "PARAM\t2\t\tDFN\t1\t\t1",
    "PDESC\t2\t\tThe patient's internal entry number.",
    "RET\t2\tDFN^NAME^SEX^DOB...",
    "RPC\t3\tBEHOVM2 VUNITS\tVUNITS\tBEHOVM2\t1\t\t\t1\t\t\t\t\t1\t1\tRET",
    "RPC\t4\tXUS CCOW VAULT PARAM\tCCOWPC\tXUSRB4\t2\tR\t3\t\t\t\t\t\t1\t1\tRES",
    "EXPLICIT SUCCESS: rpcs=4 description-lines=1 parameters=1"
  ].join("\n") + "\n"

  # Write the four rpms-ops assets for TAG into DIR (what bin/release_inventory.sh produces).
  def write_inventory(dir, tag: TAG, registry: REGISTRY, bound: true, release_tag: nil, records: nil, engine: "yottadb",
                      build_commit: BUILD_COMMIT, build_release: nil, reach: REACH, reach_classes: REACH_CLASSES,
                      signatures: SIGNATURES, image_digest: "sha256:deadbeef", faces: true)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "#{tag}-broker_8994.txt"), registry)
    File.write(File.join(dir, "#{tag}-packages_9_4.txt"), PACKAGES)
    File.write(File.join(dir, "#{tag}-rpc_reach.txt"), reach)
    File.write(File.join(dir, "#{tag}-rpc_signatures.txt"), signatures)
    sha = ->(suffix) { Digest::SHA256.file(File.join(dir, "#{tag}-#{suffix}")).hexdigest }
    prov = {
      "schema_version" => 3, "label" => "inventory-#{tag}", "release_tag" => release_tag || tag,
      "artifact_sha256" => "sha256:deadbeef", "engine" => engine, "m_backend" => engine,
      "artifact_bound" => bound, "transport" => "local", "container" => "rpms-ydb",
      "captured_at" => "2026-09-03T12:00:00Z", "tool_git_sha" => "0123456789abcdef",
      "dumps" => { "packages" => { "records" => 2 }, "builds" => { "records" => 9 },
                   "rpcs" => { "records" => records || registry.lines.count } }
    }
    if faces
      prov["rpc_reach"] = { "sha256" => sha.("rpc_reach.txt"), "records" => reach.lines.count, "classes" => reach_classes }
      prov["rpc_signatures"] = { "sha256" => sha.("rpc_signatures.txt"), "rpcs" => registry.lines.count }
      prov["image"] = { "repository" => "ghcr.io/lakeraven/rpms-ydb", "digest" => image_digest,
                        "ref" => "ghcr.io/lakeraven/rpms-ydb@#{image_digest}" }
    end
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
      assert_equal 5, Lock::ASSET_SUFFIXES.size
      assert_equal Digest::SHA256.hexdigest(REGISTRY), inv.shas["#{TAG}-broker_8994.txt"]
      assert_equal TAG, inv.to_source["tag"]
      assert_equal "sha256:deadbeef", inv.to_source["artifact_sha256"]
      assert_equal "bcer-9.0", inv.rpms_version
      assert_equal BUILD_COMMIT, inv.build_commit
      assert_equal BUILD_COMMIT, inv.to_source["build_commit"]
      assert_equal "0123456789abcdef", inv.to_source["inventory_tool_commit"]
      assert_equal Digest::SHA256.hexdigest(REACH), inv.to_source["rpc_reach_sha256"]
      assert_equal "ghcr.io/lakeraven/rpms-ydb@sha256:deadbeef", inv.image_ref
      assert_equal REACH_CLASSES.sort.to_h, inv.surface.reach_counts
    end
  end

  # --- the reach face and the signatures (#394) ----------------------------------------------

  def test_verify_dir_rejects_a_release_without_the_reach_face
    Dir.mktmpdir do |dir|
      write_inventory(dir)
      File.delete(File.join(dir, "#{TAG}-rpc_reach.txt"))
      e = assert_raises(Lock::Error) { Lock.verify_dir(TAG, dir) }
      assert_match(/missing or empty asset #{TAG}-rpc_reach.txt/, e.message)
    end
  end

  def test_verify_dir_rejects_a_provenance_without_the_reach_face
    Dir.mktmpdir do |dir|
      e = assert_raises(Lock::Error) { Lock.verify_dir(TAG, write_inventory(dir, faces: false)) }
      assert_match(/no rpc_reach face/, e.message)
    end
  end

  def test_verify_dir_rejects_a_reach_face_out_of_step_with_the_registry
    Dir.mktmpdir do |dir|
      reach = REACH.lines.reverse.join
      e = assert_raises(Lock::Error) { Lock.verify_dir(TAG, write_inventory(dir, reach: reach)) }
      assert_match(/rpc_reach.txt does not name the registry's 4 RPCs in order/, e.message)
    end
  end

  def test_verify_dir_rejects_reach_classes_the_provenance_does_not_count
    Dir.mktmpdir do |dir|
      e = assert_raises(Lock::Error) { Lock.verify_dir(TAG, write_inventory(dir, reach_classes: { "client-callable" => 4 })) }
      assert_match(/classes/, e.message)
    end
  end

  def test_verify_dir_rejects_an_unknown_reach_class
    Dir.mktmpdir do |dir|
      reach = REACH.sub("no-context", "maybe-callable")
      e = assert_raises(Lock::Error) { Lock.verify_dir(TAG, write_inventory(dir, reach: reach)) }
      assert_match(/maybe-callable/, e.message)
    end
  end

  def test_verify_dir_rejects_a_truncated_signatures_walk
    Dir.mktmpdir do |dir|
      sigs = SIGNATURES.lines[0..-2].join
      e = assert_raises(Lock::Error) { Lock.verify_dir(TAG, write_inventory(dir, signatures: sigs)) }
      assert_match(/EXPLICIT SUCCESS/, e.message)
    end
  end

  def test_verify_dir_rejects_an_image_that_is_not_the_artifact
    Dir.mktmpdir do |dir|
      e = assert_raises(Lock::Error) { Lock.verify_dir(TAG, write_inventory(dir, image_digest: "sha256:0ther")) }
      assert_match(/image.digest/, e.message)
    end
  end

  def test_the_surface_reads_signatures_reach_and_registry_together
    Dir.mktmpdir do |dir|
      surface = Lock.verify_dir(TAG, write_inventory(dir)).surface
      select = surface["ORWPT SELECT"]
      assert_equal "SELECT^ORWPT", select.entry_point
      assert_equal "client-callable", select.reach
      assert select.callable?
      assert_equal %w[Y DFN], select.formals
      assert_equal [ "DFN" ], select.params.map(&:name)
      assert_equal [ "The patient's internal entry number." ], select.params.first.description
      assert select.params.first.required
      assert_equal [ "DFN^NAME^SEX^DOB..." ], select.returns
      assert_equal [ "Returns 1 when the broker is alive." ], surface["XWB IM HERE"].description
      assert_equal [ "xwb" ], surface["XWB IM HERE"].exempt_on
      assert_equal "3", surface["XUS CCOW VAULT PARAM"].inactive
      assert_equal({ "XUS CCOW VAULT PARAM" => "no-context" }, surface.uncallable)
      assert_equal 2, surface.packages.size
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
      assert_equal 4, reloaded.surfaces(inventories_dir: File.join(root, "inventories"))[TAG].names.size
      assert_equal "ghcr.io/lakeraven/rpms-ydb@sha256:deadbeef", reloaded[TAG]["image"]
      assert_equal REACH_CLASSES.sort.to_h, reloaded[TAG]["reach_classes"]

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
