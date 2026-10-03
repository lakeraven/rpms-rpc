# frozen_string_literal: true

# The fake freeze (#350, ADR 0009): no NEW test proves RPC behaviour against a
# reply we wrote. A test file that uses a fake must be listed in
# test/fake_allowlist.txt; see that file's header for the two sections.
#
# Also: a test never skips silently. The one acceptable skip is
# LiveSpec::Test#skip_tracked("#NNN", why), which names the issue and is
# counted, by issue, in the live run's summary.
require "open3"

module FakeFreeze
  ROOT = File.expand_path("..", __dir__)
  ALLOWLIST = File.join(ROOT, "test", "fake_allowlist.txt")
  SECTIONS = %w[convert permanent].freeze
  # The guard's own test quotes every fake and skip it detects.
  SELF = "test/rpms_rpc/fake_freeze_test.rb"

  # kind => pattern. Comment lines are ignored, so a converted file may still
  # say in prose what it replaced.
  FAKES = {
    "MockClient / RpmsRpc.mock!" => /\bMock(?:Fhir)?Client\b|\bmock(?:_fhir)?!/,
    "seed_* canned reply" => /\.seed(?:_[a-z_]+)?\b/,
    "hand-written socket" => /\b(?:Fake|Recording)Socket\b|\bclass\s+\w*Socket\b/,
    "scripted client double" => /\b(?:RawResponse|Scripted)Client\b|\bclass\s+\w*Client\b/,
    "forged client state" => /\binstance_variable_set\(\s*:@/,
    "stubbed method" => /\.stub\(/
  }.freeze

  # `skip` called as a method: not skip_tracked, not a symbol or a word in a string.
  BARE_SKIP = /(?<![\w:."'])skip(?=[\s(]|$)/

  module_function

  def code_lines(source)
    source.each_line.reject { |l| l.lstrip.start_with?("#") }
  end

  # The fake kinds a test file's source uses.
  def fakes_in(source)
    code = code_lines(source).join
    FAKES.select { |_, re| code.match?(re) }.keys
  end

  # Line numbers (1-based) of bare skips.
  def bare_skips(source)
    source.each_line.with_index(1).filter_map do |line, n|
      next if line.lstrip.start_with?("#")

      n if line.gsub(/"[^"]*"|'[^']*'/, "").match?(BARE_SKIP)
    end
  end

  # { "convert" => [paths], "permanent" => [paths] } from the allowlist text.
  # A permanent entry must carry its reason after the path ("path  # why").
  def parse_allowlist(text)
    lists = SECTIONS.to_h { |s| [ s, [] ] }
    reasons = {}
    section = nil
    text.each_line do |raw|
      line = raw.strip
      next if line.empty? || line.start_with?("#")

      if (m = line.match(/\A\[(\w+)\]\z/))
        raise ArgumentError, "unknown section [#{m[1]}]" unless SECTIONS.include?(m[1])

        section = m[1]
        next
      end
      raise ArgumentError, "entry before a section: #{line}" unless section

      path, reason = line.split(/\s+#\s*/, 2)
      lists[section] << path
      reasons[path] = reason
    end
    [ lists, reasons ]
  end

  def test_files(root = ROOT)
    Dir.glob("test/**/*_test.rb", base: root).sort - [ SELF ]
  end

  # The allowlist as the base branch has it: GITHUB_BASE_REF in CI (empty on
  # a push, so main), origin/main locally. nil when the base has no list yet;
  # :unresolved when the base ref is not in this checkout.
  def base_allowlist(root = ROOT)
    ref = base_ref(root)
    return :unresolved unless ref

    text, status = Open3.capture2e("git", "-C", root, "show", "#{ref}:test/fake_allowlist.txt")
    status.success? ? text : nil
  end

  def base_branch = ENV["GITHUB_BASE_REF"].to_s.empty? ? "main" : ENV["GITHUB_BASE_REF"]

  def base_ref(root = ROOT)
    [ "origin/#{base_branch}", base_branch ].find do |ref|
      _, status = Open3.capture2e("git", "-C", root, "rev-parse", "--verify", "--quiet", "#{ref}^{commit}")
      status.success?
    end
  end

  def base_unresolved_message
    "cannot resolve the base branch #{base_branch.inspect}, so the allowlist's [convert] section cannot be " \
      "checked against it. Run `git fetch origin #{base_branch}` (CI needs fetch-depth: 0)."
  end

  def generate(root = ROOT)
    test_files(root).reject { |p| fakes_in(File.read(File.join(root, p))).empty? }
  end
end
