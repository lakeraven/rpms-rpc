# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../lib/rpms_rpc"
require_relative "../../lib/rpms_rpc/test_roles"

class RpmsRpc::NoRoleVocabularyTest < Minitest::Test
  # The gem reports which keys a user holds; roles and capabilities are the
  # host's (ADR 0010, #359). Capabilities and UserRoles are removed (#445), so
  # no file under lib/ may carry role or capability vocabulary.

  ROLE_BARE_WORDS = %w[
    prc_supervisor prc_manager prc_tech case_manager consult_manager
    eligibility_verify bh_provider bh_supervisor dental_provider
    dental_supervisor chs_approve chs_clerk
  ].freeze

  ROLE_WORD_PATTERN = Regexp.union(
    ROLE_BARE_WORDS.map { |word| /\b#{word}\b/ }
  )

  CAPABILITY_BARE_WORDS = %w[
    view_patients view_referrals create_referrals edit_own_referrals
    update_referral_status approve_referrals deny_referrals manage_referrals
    view_own_referrals process_claims verify_eligibility manage_consults
    manage_scheduling access_behavioral_health access_dental
  ].freeze

  CAPABILITY_WORD_PATTERN = Regexp.union(
    CAPABILITY_BARE_WORDS.map { |word| /\b#{word}\b/ }
  )

  VOCABULARY_PATTERNS = [
    ROLE_WORD_PATTERN,
    CAPABILITY_WORD_PATTERN,
    /\bcan_\w+\?/,
    /ROLE_PERMISSIONS/,
    /USER_CLASS_MAP/,
    /REVERSE_CLASS_MAP/,
    /DEPRECATED_CHECKS/
  ].freeze

  def vocabulary?(source)
    VOCABULARY_PATTERNS.any? { |pat| source.match?(pat) }
  end

  def read_source_utf8(path)
    File.binread(path).encode("UTF-8", invalid: :replace, undef: :replace)
  end

  def test_the_role_layer_is_removed
    refute RpmsRpc.const_defined?(:Capabilities, false), "Capabilities is removed (#445)"
    refute RpmsRpc.const_defined?(:UserRoles, false), "UserRoles is removed (#445)"
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

  def test_vocabulary_detects_copied_permission_table_shape
    snippet = <<~RUBY
      module RpmsRpc; module HostPolicyCopy; PERMS = { "admin" => %i[view_patients approve_referrals] }.freeze; end; end
    RUBY
    assert vocabulary?(snippet), "permission-table copy must be flagged as role vocabulary"
  end

  # The live harness's test roles (TestRoles, #452) are the accounts a live
  # spec signs on as, named for the openrpms-ux persona each plays; the gem
  # grants nothing by them. These two files name them, so each role's name,
  # and only that, is not read as vocabulary there; every other pattern still
  # applies to them.
  TEST_ROLE_FILES = %w[lib/rpms_rpc/test_roles.rb lib/rpms_rpc/daily_report.rb].freeze

  def without_test_role_names(source)
    RpmsRpc::TestRoles.names.reduce(source) { |text, name| text.gsub(/\b#{name}\b/, "test_role") }
  end

  def test_a_test_role_name_is_read_as_vocabulary_outside_the_role_table
    assert vocabulary?("ROLE = :bh_provider"), "a role name elsewhere in lib/ is still vocabulary"
    refute vocabulary?(without_test_role_names("ROLE = :bh_provider")), "the role table may name its test role"
    assert vocabulary?(without_test_role_names("can_approve_chs?")), "the role table is still scanned for everything else"
  end

  def test_lib_carries_no_role_or_capability_vocabulary
    root = File.expand_path("../..", __dir__)
    violations = Dir.glob(File.join(root, "lib", "**", "*")).sort.select { |abs| File.file?(abs) }
                    .select do |abs|
                      source = read_source_utf8(abs)
                      source = without_test_role_names(source) if TEST_ROLE_FILES.include?(abs.delete_prefix("#{root}/"))
                      vocabulary?(source)
                    end
                    .map { |abs| abs.delete_prefix("#{root}/") }

    assert_empty violations, "role/capability vocabulary found under lib/: #{violations.join(', ')}"
  end
end
