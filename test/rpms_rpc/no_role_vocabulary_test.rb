# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../lib/rpms_rpc"

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

  def test_lib_carries_no_role_or_capability_vocabulary
    root = File.expand_path("../..", __dir__)
    violations = Dir.glob(File.join(root, "lib", "**", "*")).sort.select { |abs| File.file?(abs) }
                    .select { |abs| vocabulary?(read_source_utf8(abs)) }
                    .map { |abs| abs.delete_prefix("#{root}/") }

    assert_empty violations, "role/capability vocabulary found under lib/: #{violations.join(', ')}"
  end
end
