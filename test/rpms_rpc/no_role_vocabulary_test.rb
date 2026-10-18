# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../lib/rpms_rpc/version"

class RpmsRpc::NoRoleVocabularyTest < Minitest::Test
  # Delete both files and this allowlist together at removal (#359 follow-up).
  ALLOWLISTED = [
    "lib/rpms_rpc/capabilities.rb",
    "lib/rpms_rpc/user_roles.rb"
  ].freeze

  ROLE_BARE_WORDS = %w[
    prc_supervisor prc_manager prc_tech case_manager consult_manager
    eligibility_verify bh_provider bh_supervisor dental_provider
    dental_supervisor chs_approve chs_clerk
  ].freeze

  ROLE_WORD_PATTERN = Regexp.union(
    ROLE_BARE_WORDS.map { |word| /\b#{word}\b/ }
  )

  VOCABULARY_PATTERNS = [
    ROLE_WORD_PATTERN,
    /\bcan_\w+\?/,
    /ROLE_PERMISSIONS/,
    /USER_CLASS_MAP/,
    /REVERSE_CLASS_MAP/,
    /DEPRECATED_CHECKS/
  ].freeze

  def vocabulary?(source)
    VOCABULARY_PATTERNS.any? { |pat| source.match?(pat) }
  end

  def allowlisted_sources
    root = File.expand_path("../..", __dir__)
    ALLOWLISTED.map { |rel| File.read(File.join(root, rel), encoding: "UTF-8") }
  end

  def test_each_vocabulary_pattern_matches_an_allowlisted_file
    sources = allowlisted_sources
    VOCABULARY_PATTERNS.each_with_index do |pat, idx|
      assert sources.any? { |src| src.match?(pat) },
             "pattern #{idx} must match capabilities.rb or user_roles.rb"
    end
  end

  def test_vocabulary_detects_copied_deprecated_checks_shape
    snippet = <<~RUBY
      ZZ_PROBE = {
        can_approve_chs?: [ %i[prc_supervisor prc_manager], [] ],
      }.freeze
      ZZ_PROBE.each_key do |check|
        define_singleton_method(check) { |_user| true }
      end
    RUBY
    assert vocabulary?(snippet), "probe-like copy must be flagged as role vocabulary"
  end

  def test_lib_defines_role_vocabulary_only_in_allowlisted_files
    root = File.expand_path("../..", __dir__)
    violations = []

    ALLOWLISTED.each do |rel|
      path = File.join(root, rel)
      assert_path_exists path, "allowlisted file must exist: #{rel}"
    end

    Dir.glob(File.join(root, "lib/**/*.rb")).sort.each do |abs|
      rel = abs.delete_prefix("#{root}/")
      next if ALLOWLISTED.include?(rel)

      source = File.read(abs, encoding: "UTF-8")
      next unless vocabulary?(source)

      violations << rel
    end

    assert_empty violations,
                 "role/capability vocabulary must only live in #{ALLOWLISTED.join(', ')}; " \
                 "also found in: #{violations.join(', ')}"
  end
end
