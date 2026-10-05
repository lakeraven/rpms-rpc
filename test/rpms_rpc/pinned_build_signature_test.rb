# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "yaml"
require "rpms_rpc/conformance/inventory_lock"
require "rpms_rpc/wire_capture"

# rpms-rpc conforms to the RPC signature of a named rpms-ops build (rpms-rpc#222).
#
# rpms-ops attaches to every gated release the #8994 + #9.4 inventory that build
# serves, plus the build record (PROVENANCE.json) naming the commit it was cut
# from. `rake conformance:pin RELEASE=<tag>` downloads those assets, verifies
# them, commits them unchanged under data/inventories/<tag>/, derives the
# reference fingerprint and writes data/fingerprints/rpms-ops.lock.yml.
#
# This test holds the pin to what it claims, offline: the lock names the build,
# the committed bytes are the pinned bytes, the fingerprint came from them, and
# every reader in this repo (fixtures, rpc:coverage) uses that one signature.
class PinnedBuildSignatureTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  FINGERPRINTS_DIR = File.join(ROOT, "data/fingerprints")
  INVENTORIES_DIR = File.join(ROOT, "data/inventories")
  Lock = RpmsRpc::Conformance::InventoryLock
  LOCK = Lock.load(File.join(FINGERPRINTS_DIR, Lock::DEFAULT_PATH))

  # AC 1: the pin names the build.
  def test_the_lock_names_the_rpms_ops_build_each_pin_came_from
    refute_empty LOCK.entries, "nothing pinned in #{LOCK.path}"

    LOCK.entries.each do |tag, entry|
      parts = Lock.parse_tag(tag)
      refute_nil parts, "#{tag} is not a bcer-<version>-<yyyymmdd>-<commit>-<ydb|iris> build tag"
      assert_equal parts[:rpms_version], entry["rpms_version"], "#{tag}: rpms_version"
      assert_equal parts[:engine], entry["engine"], "#{tag}: engine"
      assert_match(/\A[0-9a-f]{40}\z/, entry["build_commit"].to_s, "#{tag}: build_commit")
      assert entry["build_commit"].start_with?(parts[:short_commit]),
             "#{tag}: build_commit #{entry['build_commit']} is not the commit the tag names"
      assert_match(/\Asha256:[0-9a-f]{64}\z/, entry["artifact_sha256"].to_s, "#{tag}: artifact_sha256")
      assert_match(/\A[0-9a-f]{40}\z/, entry["inventory_tool_commit"].to_s, "#{tag}: inventory_tool_commit")
      # The image a -ydb release pins, by digest (rpms-ops#727), is the artifact the lock names.
      assert_equal "ghcr.io/lakeraven/rpms-ydb@#{entry['artifact_sha256']}", entry["image"], "#{tag}: image" if parts[:engine] == "yottadb"
      assert_equal RpmsRpc::Conformance::BuildSurface::REACH_CLASSES.sort & entry["reach_classes"].keys, entry["reach_classes"].keys.sort,
                   "#{tag}: reach_classes names only reach classes"
      assert_equal entry["rpcs"], entry["reach_classes"].values.sum, "#{tag}: every pinned RPC has one reach class"
      expected_assets = (Lock::ASSET_SUFFIXES + [ Lock::BUILD_RECORD_SUFFIX ]).map { |s| "#{tag}-#{s}" }.sort
      assert_equal expected_assets, entry["assets"].keys.sort, "#{tag}: pinned assets"
      entry["assets"].each_value { |sha| assert_match(/\A[0-9a-f]{64}\z/, sha) }
    end
  end

  # AC 2 + AC 3: the committed signature is the pinned bytes, and the reference
  # fingerprint was derived from exactly them.
  def test_the_committed_signature_and_fingerprint_match_the_lock
    LOCK.entries.each_key do |tag|
      assert File.directory?(File.join(INVENTORIES_DIR, tag)),
             "#{tag}: the pinned signature is not committed under data/inventories/#{tag}/"
    end
    problems = LOCK.check(fingerprints_dir: FINGERPRINTS_DIR, inventories_dir: INVENTORIES_DIR, require_inventories: true)
    assert_empty problems, "pinned signature drifted from the lock:\n  #{problems.join("\n  ")}"
  end

  def test_a_byte_changed_in_the_committed_signature_fails_the_check
    tag = LOCK.entries.keys.first
    Dir.mktmpdir do |tmp|
      FileUtils.cp_r(File.join(INVENTORIES_DIR, tag), tmp)
      dump = File.join(tmp, tag, "#{tag}-broker_8994.txt")
      File.write(dump, File.read(dump).sub("ORWPT SELECT^SELECT^ORWPT", "ORWPT SELECT^SELECT^ORWPX"))
      problems = LOCK.check(fingerprints_dir: FINGERPRINTS_DIR, inventories_dir: tmp, require_inventories: true)
      refute_empty problems.grep(/#{Regexp.escape(tag)}/)
    end
  end

  # AC 5: fixtures conform to the pinned build. A fixture's cite leads with the
  # entry point it read; the build's #8994 entry says which entry point the RPC
  # name actually runs (FASTVIT^ORQQVI, not VITALS^ORQQVI, for ORQQVI VITALS: #188).
  def test_every_wire_fixture_cites_the_entry_point_the_pinned_build_registers
    builds = LOCK.surfaces(inventories_dir: INVENTORIES_DIR)
    fixtures = RpmsRpc::WireCapture::Fixture.load_all
    refute_empty fixtures

    problems = builds.flat_map do |tag, surface|
      fixtures.filter_map do |fixture|
        name = File.basename(fixture.path)
        rpc = surface[fixture.rpc]
        next "#{name}: #{fixture.rpc} is not registered on #{tag}" unless rpc

        registered = rpc.entry_point
        cited = Lock.cited_entry_point(fixture.cite)
        next if cited == registered

        "#{name}: cite leads with #{cited.inspect}, #{tag} registers #{fixture.rpc} at #{registered}"
      end
    end
    assert_empty problems, "wire fixtures disagree with the pinned build:\n  #{problems.join("\n  ")}"
  end

  def test_cited_entry_point_reads_the_leading_tag_and_routine
    assert_equal "FASTVIT^ORQQVI", Lock.cited_entry_point("FASTVIT^ORQQVI (bcer-9.0-ydb r/ORQQVI.m:61-84): the rows")
    assert_equal "VUNITS^BEHOVM2", Lock.cited_entry_point("VUNITS^BEHOVM2 (BEHOVM2.m:186-196) -> UNITS^BEHOVM: x")
    assert_nil Lock.cited_entry_point("the routine builds TYPE^VALUE rows")
    assert_nil Lock.cited_entry_point(nil)
  end

  # AC 6: one source. rpc:coverage reads the pinned signature itself; the
  # names-only copies it used to keep are gone.
  def test_rpc_coverage_reads_the_pinned_signature
    cfg = YAML.safe_load_file(File.join(ROOT, "data/rpc_coverage/config.yml"))
    tag = cfg.fetch("release")
    assert LOCK[tag], "rpc:coverage release #{tag} is not pinned in #{LOCK.path}"
    assert_equal "data/inventories/#{tag}/#{tag}-broker_8994.txt", cfg.fetch("registry")
    assert_equal "data/inventories/#{tag}/#{tag}-packages_9_4.txt", cfg.fetch("packages")
    refute File.exist?(File.join(ROOT, "data/rpc_coverage/registry")),
           "data/rpc_coverage/registry/ held a names-only copy of a signature; read data/inventories/ instead"
  end
end
