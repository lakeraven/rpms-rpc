# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "yaml"
require_relative "../../tools/openapi/rpcs_pin"

# rake openapi:pin against a release whose rpcs.json header names a short commit, read over REST
# (rpms-rpc#639). Two pure functions carry the decisions: build_commit resolves the header's 7 to 40 hex
# commit to the full commit the inventory lock (rake conformance:pin) already verified, and release_asset
# picks one asset's id and sha256 out of the REST release JSON. Both fail closed: absence never verifies.
# Everything here is synthetic; the real data/fingerprints lock is never read.
class OpenApiRpcsPinReleaseTest < Minitest::Test
  PIN = OpenApi::RpcsPin
  INVENTORY_LOCK = "data/fingerprints/rpms-ops.lock.yml"
  SHORT = "abcdef0"
  FULL = "#{SHORT}#{'123456789' * 3}abcdef".freeze
  OTHER = "#{'0fedcba' * 5}01234".freeze
  TAG = "bcer-9.0-20990101-#{SHORT}-ydb".freeze
  ASSET = "#{TAG}-rpcs.json".freeze
  DIGEST = ("0123456789abcdef" * 4).freeze

  def setup
    @root = Dir.mktmpdir("rpcs-pin-release")
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  # --- build_commit ---

  def test_build_commit_resolves_a_short_header_commit_to_the_locks_full_commit
    write_lock
    assert_equal 40, FULL.size
    assert_equal FULL, PIN.build_commit(SHORT, tag: TAG, root: @root)
    assert_equal FULL, PIN.build_commit(FULL[0, 12], tag: TAG, root: @root)
    assert_equal FULL, PIN.build_commit(FULL, tag: TAG, root: @root)
  end

  def test_build_commit_refuses_when_the_inventory_lock_is_missing
    assert_raises(OpenApi::Refused) { PIN.build_commit(SHORT, tag: TAG, root: @root) }
  end

  def test_build_commit_refuses_a_tag_the_lock_does_not_pin_and_names_conformance_pin
    write_lock("bcer-9.0-20990102-#{OTHER[0, 7]}-ydb" => { "build_commit" => FULL })
    e = assert_raises(OpenApi::Refused) { PIN.build_commit(SHORT, tag: TAG, root: @root) }
    assert_match(/conformance:pin/, e.message)
    assert_includes e.message, TAG
  end

  def test_build_commit_refuses_a_lock_entry_without_a_build_commit
    write_lock(TAG => { "inventory_sha256" => DIGEST })
    assert_raises(OpenApi::Refused) { PIN.build_commit(SHORT, tag: TAG, root: @root) }
  end

  def test_build_commit_refuses_a_lock_build_commit_that_is_not_40_lowercase_hex
    [ SHORT, FULL[0, 39], "#{FULL}0", FULL.upcase, "#{FULL[0, 39]}g", "", nil ].each do |bad|
      write_lock(TAG => { "build_commit" => bad })
      assert_raises(OpenApi::Refused, "lock build_commit #{bad.inspect}") { PIN.build_commit(SHORT, tag: TAG, root: @root) }
    end
  end

  def test_build_commit_refuses_a_nil_header_commit
    write_lock
    assert_raises(OpenApi::Refused) { PIN.build_commit(nil, tag: TAG, root: @root) }
  end

  def test_build_commit_refuses_a_blank_header_commit
    write_lock
    [ "", "   " ].each do |blank|
      assert_raises(OpenApi::Refused, "header commit #{blank.inspect}") { PIN.build_commit(blank, tag: TAG, root: @root) }
    end
  end

  def test_build_commit_refuses_a_header_commit_shorter_than_7
    write_lock
    assert_raises(OpenApi::Refused) { PIN.build_commit(FULL[0, 6], tag: TAG, root: @root) }
  end

  def test_build_commit_refuses_a_header_commit_longer_than_40
    write_lock
    assert_raises(OpenApi::Refused) { PIN.build_commit("#{FULL}0", tag: TAG, root: @root) }
  end

  def test_build_commit_refuses_an_uppercase_header_commit
    write_lock
    assert_raises(OpenApi::Refused) { PIN.build_commit(SHORT.upcase, tag: TAG, root: @root) }
    assert_raises(OpenApi::Refused) { PIN.build_commit(FULL.upcase, tag: TAG, root: @root) }
  end

  def test_build_commit_refuses_a_non_hex_header_commit
    write_lock
    [ "abcdefg", "abcdef0\n", "#{SHORT} ", "abc-ef0" ].each do |bad|
      assert_raises(OpenApi::Refused, "header commit #{bad.inspect}") { PIN.build_commit(bad, tag: TAG, root: @root) }
    end
  end

  def test_build_commit_refuses_a_short_header_commit_that_abbreviates_a_different_commit
    write_lock
    assert_raises(OpenApi::Refused) { PIN.build_commit(OTHER[0, 7], tag: TAG, root: @root) }
    # Inside the build commit but not at its start: a prefix, not a substring.
    assert_raises(OpenApi::Refused) { PIN.build_commit(FULL[1, 7], tag: TAG, root: @root) }
  end

  def test_build_commit_refuses_a_full_header_commit_that_differs_from_the_lock
    write_lock
    assert_equal 40, OTHER.size
    assert_raises(OpenApi::Refused) { PIN.build_commit(OTHER, tag: TAG, root: @root) }
    assert_raises(OpenApi::Refused) { PIN.build_commit("#{FULL[0, 39]}0", tag: TAG, root: @root) }
  end

  # --- release_asset ---

  def test_release_asset_returns_the_named_assets_id_and_bare_sha256
    assert_equal({ id: 1002, digest: DIGEST }, PIN.release_asset(release, ASSET))
  end

  def test_release_asset_refuses_a_draft_release
    assert_raises(OpenApi::Refused) { PIN.release_asset(release("draft" => true), ASSET) }
  end

  def test_release_asset_refuses_a_prerelease
    assert_raises(OpenApi::Refused) { PIN.release_asset(release("prerelease" => true), ASSET) }
  end

  def test_release_asset_refuses_a_release_without_a_draft_key
    assert_raises(OpenApi::Refused) { PIN.release_asset(release.except("draft"), ASSET) }
  end

  def test_release_asset_refuses_a_release_without_a_prerelease_key
    assert_raises(OpenApi::Refused) { PIN.release_asset(release.except("prerelease"), ASSET) }
  end

  def test_release_asset_refuses_when_no_asset_has_exactly_that_name
    assert_raises(OpenApi::Refused) { PIN.release_asset(release("assets" => []), ASSET) }
    # The release carries <tag>-rpcs.json.sha256 and <tag>-inventory.json: neither a longer name, a
    # shorter one, nor a name that contains the wanted one is a match.
    others = release("assets" => release["assets"].reject { |a| a["name"] == ASSET })
    assert_raises(OpenApi::Refused) { PIN.release_asset(others, ASSET) }
    assert_raises(OpenApi::Refused) { PIN.release_asset(release, "rpcs.json") }
    assert_raises(OpenApi::Refused) { PIN.release_asset(release, TAG) }
  end

  def test_release_asset_refuses_an_asset_without_a_digest
    assert_raises(OpenApi::Refused) { PIN.release_asset(with_asset { |a| a.delete("digest") }, ASSET) }
  end

  def test_release_asset_refuses_a_nil_digest
    assert_raises(OpenApi::Refused) { PIN.release_asset(with_asset("digest" => nil), ASSET) }
  end

  def test_release_asset_refuses_a_digest_without_the_sha256_prefix
    [ DIGEST, "sha512:#{DIGEST}", "SHA256:#{DIGEST}" ].each do |bad|
      assert_raises(OpenApi::Refused, "digest #{bad.inspect}") { PIN.release_asset(with_asset("digest" => bad), ASSET) }
    end
  end

  def test_release_asset_refuses_a_digest_that_is_not_64_lowercase_hex
    [ "sha256:", "sha256:#{DIGEST[0, 63]}", "sha256:#{DIGEST}0", "sha256:#{DIGEST.upcase}", "sha256:#{DIGEST[0, 63]}g" ].each do |bad|
      assert_raises(OpenApi::Refused, "digest #{bad.inspect}") { PIN.release_asset(with_asset("digest" => bad), ASSET) }
    end
  end

  def test_release_asset_refuses_an_asset_id_that_is_not_a_positive_integer
    [ nil, 0, -1, "1002", 1002.0 ].each do |bad|
      assert_raises(OpenApi::Refused, "asset id #{bad.inspect}") { PIN.release_asset(with_asset("id" => bad), ASSET) }
    end
    assert_raises(OpenApi::Refused) { PIN.release_asset(with_asset { |a| a.delete("id") }, ASSET) }
  end

  private

  # The inventory lock as rake conformance:pin writes it, under the temp root.
  def write_lock(releases = { TAG => { "build_commit" => FULL } })
    path = File.join(@root, INVENTORY_LOCK)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, YAML.dump("repo" => "lakeraven/rpms-ops", "releases" => releases))
  end

  # GET repos/<repo>/releases/tags/<tag>, the fields the pin reads: a published release with the wanted
  # asset between two whose names contain or extend it.
  def release(overrides = {})
    {
      "tag_name" => TAG,
      "draft" => false,
      "prerelease" => false,
      "assets" => [
        { "id" => 1001, "name" => "#{TAG}-inventory.json", "digest" => "sha256:#{'a' * 64}" },
        { "id" => 1002, "name" => ASSET, "digest" => "sha256:#{DIGEST}" },
        { "id" => 1003, "name" => "#{ASSET}.sha256", "digest" => "sha256:#{'b' * 64}" }
      ]
    }.merge(overrides)
  end

  # The release with the wanted asset changed: fields merged in, then the block (if any) applied to it.
  def with_asset(fields = {})
    r = release
    asset = r["assets"].find { |a| a["name"] == ASSET }
    asset.merge!(fields)
    yield asset if block_given?
    r
  end
end
