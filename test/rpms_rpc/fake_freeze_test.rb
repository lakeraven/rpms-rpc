# frozen_string_literal: true

require "minitest/autorun"
require "set"
require_relative "../fake_freeze"

# The fake freeze (#350, ADR 0009). A test file that proves RPC behaviour
# against a reply we wrote is either on test/fake_allowlist.txt or fails here.
# The [convert] section may only shrink; a file leaves it in the PR that
# converts it to a live spec. And no test skips without naming an issue.
class FakeFreezeTest < Minitest::Test
  ROOT = FakeFreeze::ROOT

  # -- the detector ------------------------------------------------------------

  def test_detects_each_kind_of_fake
    {
      "RpmsRpc.mock!" => "MockClient / RpmsRpc.mock!",
      "c = RpmsRpc::MockClient.new" => "MockClient / RpmsRpc.mock!",
      'mock.seed_text("ORWPT ID INFO", "x")' => "seed_* canned reply",
      "mock.seed(\"ORWU USERINFO\", [])" => "seed_* canned reply",
      "sock = FakeSocket.new(bytes)" => "hand-written socket",
      "class StallingSocket" => "hand-written socket",
      "RawResponseClient.new(reply)" => "scripted client double",
      "class ProbingClient" => "scripted client double",
      "client.instance_variable_set(:@socket, io)" => "forged client state",
      "TCPSocket.stub(:new, nil) { }" => "stubbed method"
    }.each do |source, kind|
      assert_includes FakeFreeze.fakes_in(source), kind, source
    end
  end

  def test_a_live_spec_or_a_comment_is_not_a_fake
    assert_empty FakeFreeze.fakes_in(File.read(File.join(ROOT, "test/live/scheduling_hospital_locations_live_test.rb")))
    assert_empty FakeFreeze.fakes_in("# this replaced RpmsRpc.mock! and seed_text\nRpmsRpc::Patient.find(1)\n")
  end

  def test_detects_a_bare_skip_and_only_a_bare_skip
    assert_equal [ 1, 2, 3 ], FakeFreeze.bare_skips(%(skip "no data"\n  skip("x") if y\nskip\n))
    assert_empty FakeFreeze.bare_skips(%(skip_tracked "#350", "why"\n# skip in prose\nputs "we skip nothing"\nskips = 0\n:skip\n))
  end

  def test_parses_the_two_sections_and_permanent_reasons
    lists, reasons = FakeFreeze.parse_allowlist("# header\n[convert]\na_test.rb\n\n[permanent]\nb_test.rb  # framing\n")
    assert_equal({ "convert" => [ "a_test.rb" ], "permanent" => [ "b_test.rb" ] }, lists)
    assert_equal "framing", reasons["b_test.rb"]
    assert_raises(ArgumentError) { FakeFreeze.parse_allowlist("a_test.rb\n") }
    assert_raises(ArgumentError) { FakeFreeze.parse_allowlist("[other]\n") }
  end

  # -- the tree ----------------------------------------------------------------

  def test_no_new_test_file_uses_a_fake
    unlisted = FakeFreeze.generate - allowed.values.flatten
    assert_empty unlisted, <<~MSG
      These test files test RPC behaviour against a fake (ADR 0009, #350):

        #{unlisted.join("\n  ")}

      Prove the behaviour with a live spec in test/live/ instead
      (LiveSpec::Test, run by `rake test:live` against a container).
      Only a test of a client mechanic no server produces on demand (a
      dropped socket, a malformed frame, a timeout) may use a double: add it
      to [permanent] in test/fake_allowlist.txt with the mechanic as its reason.
    MSG
  end

  def test_every_listed_file_still_exists_and_still_uses_a_fake
    stale = allowed.values.flatten.reject do |p|
      File.exist?(File.join(ROOT, p)) && FakeFreeze.fakes_in(File.read(File.join(ROOT, p))).any?
    end
    assert_empty stale, <<~MSG
      test/fake_allowlist.txt lists files that are gone or no longer use a fake:

        #{stale.join("\n  ")}

      Delete those lines: the list only shrinks.
    MSG
  end

  def test_a_file_is_listed_once_and_permanent_entries_say_why
    all = allowed.values.flatten
    assert_equal all.uniq, all, "a file is listed twice"
    unexplained = allowed["permanent"].reject { |p| reasons[p].to_s.strip.length.positive? }
    assert_empty unexplained, "a [permanent] entry needs the client mechanic it tests: `path  # why`"
  end

  # The closed half: [convert] never gains an entry relative to the base
  # branch (GITHUB_BASE_REF in CI, origin/main locally), so the list cannot be
  # grown by the same commit that adds a fake.
  def test_the_convert_section_never_grows
    base = FakeFreeze.base_allowlist
    flunk FakeFreeze.base_unresolved_message if base == :unresolved
    return if base.nil? # not on the base branch yet: this commit introduces the list

    grown = allowed["convert"] - FakeFreeze.parse_allowlist(base).first["convert"]
    assert_empty grown, "[convert] in test/fake_allowlist.txt gained entries; it may only shrink:\n  #{grown.join("\n  ")}"
  end

  def test_no_test_skips_without_a_tracked_issue
    bare = FakeFreeze.test_files.to_h { |p| [ p, FakeFreeze.bare_skips(File.read(File.join(ROOT, p))) ] }.reject { |_, v| v.empty? }
    assert_empty bare, <<~MSG
      Bare `skip` in:

        #{bare.map { |p, lines| "#{p}:#{lines.join(',')}" }.join("\n  ")}

      A test that cannot run should FAIL and say what is missing and how to
      supply it. The one acceptable skip is skip_tracked("#NNN", why) in a
      live spec; the live run's summary lists it by issue.
    MSG
  end

  private

  def allowed = parsed.first
  def reasons = parsed.last
  def parsed = (@parsed ||= FakeFreeze.parse_allowlist(File.read(FakeFreeze::ALLOWLIST)))
end
