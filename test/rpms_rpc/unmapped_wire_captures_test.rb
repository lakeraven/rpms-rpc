# frozen_string_literal: true

require "minitest/autorun"
require "digest"
require "yaml"
require "rpms_rpc/conformance/release_inventory"
require_relative "release_under_test"

# Unmapped wire captures (test/fixtures/wire_captures/unmapped/) are evidence
# for RPCs no mapping covers yet. The wire-contract gate cannot read them (it
# needs a mapping), so this test holds them to what they claim: the bytes are
# the sealed bytes, the ack label matches the ack byte, and the RPC and entry
# point are what the release they name registers (the committed fixture inventory holds that
# release's records for them, rpms-rpc#724).
class UnmappedWireCapturesTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  DIR = File.join(ROOT, "test/fixtures/wire_captures/unmapped")
  FILES = Dir.glob(File.join(DIR, "*.yml")).sort.freeze

  def docs
    @docs ||= FILES.to_h { |path| [ File.basename(path), YAML.safe_load_file(path) ] }
  end

  def test_unmapped_captures_are_committed
    refute_empty FILES, "no unmapped captures in #{DIR}"
  end

  def test_every_raw_return_matches_its_seal
    problems = docs.flat_map do |name, doc|
      doc.fetch("captures").each_with_index.filter_map do |cap, i|
        raw = cap.fetch("raw_return")
        next if Digest::SHA256.hexdigest(raw) == cap.fetch("sha256")

        "#{name} capture #{i}: raw_return does not match its sha256"
      end
    end
    assert_empty problems, problems.join("\n")
  end

  def test_the_ack_label_is_read_from_the_ack_byte
    problems = docs.flat_map do |name, doc|
      doc.fetch("captures").each_with_index.filter_map do |cap, i|
        expected = cap.fetch("raw_return").match?(/\A\d+\x01/) ? "error" : "data"
        next if cap.fetch("ack") == expected

        "#{name} capture #{i}: ack is #{cap["ack"].inspect}, the reply's ack byte says #{expected}"
      end
    end
    assert_empty problems, problems.join("\n")
  end

  def test_each_rpc_and_entry_point_are_registered_on_the_release_named
    problems = docs.filter_map do |name, doc|
      surface = ReleaseUnderTest.named(self, doc.fetch("release_tag")).surface
      rpc = surface[doc.fetch("rpc")]
      next "#{name}: #{doc["rpc"]} is not registered on #{doc["release_tag"]}" unless rpc
      next if rpc.entry_point == doc.fetch("entry_point")

      "#{name}: names #{doc["entry_point"]}, #{doc["release_tag"]} registers #{rpc.entry_point}"
    end
    assert_empty problems, problems.join("\n")
  end

  def test_each_file_is_named_for_its_rpc
    docs.each do |name, doc|
      assert_equal "#{doc.fetch("rpc").downcase.tr(" /", "--")}.yml", name
    end
  end
end
