# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "open3"
require "tmpdir"
require "rpms_rpc"
require_relative "../../tools/rpc_inventory/rpc_inventory"
require_relative "../../tools/rpc_inventory/clients"

# tools/rpc_inventory/clients.rb, behind `rake rpc:inventory_clients`. The recording is a real one: openrpms
# test/fixtures/client-trace/ydb-stack-1016-edit-referral-20261021T234618Z (a trimmed rpc-trace.sh recording of
# VueCentric), copied byte for byte under test/fixtures/rpc_inventory/client-trace/. The checkouts the task reads are
# real git repositories made in a temporary directory, holding that recording where each source keeps it.
class RpcInventoryClientsTest < Minitest::Test
  C = RpcInventory::Clients
  ROOT = File.expand_path("../..", __dir__)
  TRACE = File.expand_path("../fixtures/rpc_inventory/client-trace/ydb-stack-1016-edit-referral-20261021T234618Z", __dir__)
  LABEL = "edit-referral on YDB stack 1016, bcer-9.0-20261015-46dd047-ydb, MANAGER,SYSTEM, 2026-10-21"

  def sh(dir, *cmd)
    out, err, st = Open3.capture3(*cmd, chdir: dir)
    assert st.success?, "#{cmd.join(' ')}: #{err}"
    out
  end

  # A git repository with origin set to repo, holding files { path => source file }.
  def repo(tmp, name, repo, files)
    dir = File.join(tmp, name)
    files.each do |path, from|
      FileUtils.mkdir_p(File.dirname(File.join(dir, path)))
      FileUtils.cp(from, File.join(dir, path))
    end
    FileUtils.mkdir_p(dir)
    sh(dir, "git", "init", "-q")
    sh(dir, "git", "remote", "add", "origin", "git@github.com:#{repo}.git")
    sh(dir, "git", "add", ".")
    sh(dir, "git", "-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-q", "--allow-empty", "-m", "fixture")
    dir
  end

  def trace_files(prefix) = %w[MANIFEST.json calls.jsonl].to_h { |f| [ "#{prefix}/#{f}", File.join(TRACE, f) ] }

  # The label is the one the committed vuecentric-observed.tsv carries for this session; the counts are this trimmed copy's.
  def test_a_recording_reads_as_its_public_label_and_calls
    label, rpcs = C.trace(TRACE)
    assert_equal LABEL, label
    assert_equal({ "CIAVMRPC GETPAR" => 3, "ORWU DT" => 2 }, rpcs.select { |_, n| n > 1 })
    assert_equal 10, rpcs.values.sum
    committed = File.read(File.join(ROOT, RpcInventory::CLIENT_DIR, "vuecentric-observed.tsv"))
    assert_includes committed, "\t#{LABEL}\t"
  end

  def test_the_observed_snapshot_names_its_sources_and_gives_the_same_bytes
    Dir.mktmpdir do |tmp|
      cloud = repo(tmp, "cloud-rpms", "lakeraven/cloud-rpms", { "evidence/retained/README.md" => File.join(ROOT, "README.md") })
      openrpms = repo(tmp, "openrpms", "lakeraven/openrpms", trace_files("test/fixtures/client-trace/#{File.basename(TRACE)}"))
      body = C.observed(cloud, openrpms)
      commit = sh(openrpms, "git", "rev-parse", "HEAD")[0, 12]
      assert_includes body, "lakeraven/openrpms #{commit}"
      assert_includes body, "#   #{LABEL}: openrpms test/fixtures/client-trace/, sha256 #{Digest::SHA256.file(File.join(TRACE, 'calls.jsonl')).hexdigest}"
      refute_match(/openrpms-ux/, body)
      assert_includes body, "rpc\trecording\tcalls\nBMC GET REFERENCE DATA\t#{LABEL}\t1\n"
      assert_equal body, C.observed(cloud, openrpms)
    end
  end

  # The same session in cloud-rpms (kept out of git there) and as openrpms' trimmed fixture: the copy with more calls wins.
  def test_the_fuller_copy_of_a_session_wins
    Dir.mktmpdir do |tmp|
      cloud = repo(tmp, "cloud-rpms", "lakeraven/cloud-rpms", { "evidence/retained/README.md" => File.join(ROOT, "README.md") })
      full = File.join(cloud, "docs/analyst/rpc-trace/yotta-1016-edit-referral")
      FileUtils.mkdir_p(full)
      FileUtils.cp(File.join(TRACE, "MANIFEST.json"), full)
      File.write(File.join(full, "calls.jsonl"), File.read(File.join(TRACE, "calls.jsonl")) * 2)
      openrpms = repo(tmp, "openrpms", "lakeraven/openrpms", trace_files("test/fixtures/client-trace/#{File.basename(TRACE)}"))
      body = C.observed(cloud, openrpms)
      assert_includes body, "CIAVMRPC GETPAR\t#{LABEL}\t6\n"
      assert_includes body, "#{LABEL}: cloud-rpms docs/analyst/rpc-trace/ (not in git), sha256"
    end
  end

  def test_a_source_that_is_not_the_named_repository_or_is_dirty_fails
    Dir.mktmpdir do |tmp|
      cloud = repo(tmp, "cloud-rpms", "lakeraven/cloud-rpms", { "evidence/retained/README.md" => File.join(ROOT, "README.md") })
      openrpms = repo(tmp, "openrpms", "lakeraven/openrpms", trace_files("test/fixtures/client-trace/#{File.basename(TRACE)}"))
      assert_raises(C::Error) { C.observed(openrpms, openrpms) }
      File.write(File.join(openrpms, "test/fixtures/client-trace/#{File.basename(TRACE)}/calls.jsonl"), "")
      e = assert_raises(C::Error) { C.observed(cloud, openrpms) }
      assert_match(/uncommitted changes/, e.message)
      e = assert_raises(C::Error) { C.observed(File.join(tmp, "missing"), openrpms) }
      assert_match(/is not a directory/, e.message)
    end
  end

  # The rake task builds all four before writing any, so a missing source changes nothing.
  def test_a_missing_source_fails_explicitly_and_leaves_the_snapshots
    dir = File.join(ROOT, RpcInventory::CLIENT_DIR)
    before = Dir[File.join(dir, "*")].sort.to_h { |f| [ f, File.binread(f) ] }
    Dir.mktmpdir do |tmp|
      env = { "CLOUD_RPMS" => tmp, "OPENRPMS" => tmp, "LAKERAVEN_EHR" => tmp, "BPRM_XML" => File.join(tmp, "none.xml") }
      _, err, st = Open3.capture3(env, "bundle", "exec", "rake", "rpc:inventory_clients", chdir: ROOT)
      refute st.success?
      assert_match(/EXPLICIT FAILURE: rpc:inventory_clients: .*no snapshot was changed/, err)
    end
    assert_equal before, Dir[File.join(dir, "*")].sort.to_h { |f| [ f, File.binread(f) ] }
  end

  # BPRM's entry points are matched to each release's registered ones by tools/rpc_inventory.
  def test_the_bprm_column_matches_registered_entry_points
    dir = File.expand_path("../fixtures/rpc_inventory", __dir__)
    releases = %w[iris ydb].map { |e| RpcInventory.load_release(dir, "bcer-9.0-20261116-2a9b3fe-#{e}") }
    cli = RpcInventory.clients(ROOT)
    assert_includes cli[:bprm_entry_points], "CHK^AGGEDCHK"
    cov = { methods: [], paths: {}, replies: {}, retry: {} }
    rows = RpcInventory.rows(releases, cov, cli, {})
    assert_equal [ "AGG PATIENT EDIT CHECK", "DG SENSITIVE RECORD ACCESS", "DG SENSITIVE RECORD BULLETIN" ],
                 rows.reject { |r| r["bprm"].empty? }.map { |r| r["rpc"] }
  end
end
