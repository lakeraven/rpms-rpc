# frozen_string_literal: true

require "minitest/autorun"

class RpmsRpc::NoRoleVocabularyTest < Minitest::Test
  # Delete both files and this allowlist together at removal (#359 follow-up).
  ALLOWLISTED = [
    "lib/rpms_rpc/capabilities.rb",
    "lib/rpms_rpc/user_roles.rb"
  ].freeze

  ROLE_SYMBOL_PATTERN = /
    :prc_supervisor |
    :prc_manager    |
    :prc_tech       |
    :case_manager   |
    :consult_manager|
    :eligibility_verify|
    :bh_provider    |
    :bh_supervisor  |
    :dental_provider|
    :dental_supervisor|
    :chs_approve    |
    :chs_clerk
  /x

  VOCABULARY_PATTERNS = [
    /ROLE_PERMISSIONS/,
    /USER_CLASS_MAP/,
    ROLE_SYMBOL_PATTERN,
    /def (?:self\.)?can_\w/,
    /define_singleton_method\s*\(?\s*:can_/
  ].freeze

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
      next unless VOCABULARY_PATTERNS.any? { |pat| source.match?(pat) }

      violations << rel
    end

    assert_empty violations,
                 "role/capability vocabulary must only live in #{ALLOWLISTED.join(', ')}; " \
                 "also found in: #{violations.join(', ')}"
  end
end
