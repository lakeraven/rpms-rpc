# frozen_string_literal: true

module RpmsRpc
  # Framework-agnostic capability checks derived from RPMS security keys.
  # Used by authorization policies in any engine (Pundit, Action Policy, etc.).
  #
  # All methods accept a user-like object that responds to:
  #   - security_keys: Array of symbols (e.g., [:prc_supervisor, :consult_manager])
  #   - user_type: String (e.g., "provider", "nurse")
  #
  module Capabilities
    # PRC / CHS
    def self.can_approve_chs?(user)
      has_any_key?(user, :prc_supervisor, :prc_manager)
    end

    def self.can_process_chs?(user)
      has_any_key?(user, :prc_tech, :prc_supervisor)
    end

    def self.can_manage_chs?(user)
      has_any_key?(user, :prc_supervisor, :prc_tech, :prc_manager, :chs_approve, :chs_clerk)
    end

    # Clinical
    def self.can_manage_consults?(user)
      has_key?(user, :consult_manager)
    end

    def self.can_verify_eligibility?(user)
      has_key?(user, :eligibility_verify)
    end

    def self.can_manage_scheduling?(user)
      has_key?(user, :scheduling_admin)
    end

    # Service line access (42 CFR Part 2 separation)
    def self.can_access_behavioral_health?(user)
      has_any_key?(user, :bh_provider, :bh_supervisor)
    end

    def self.can_access_dental?(user)
      has_any_key?(user, :dental_provider, :dental_supervisor)
    end

    # Role-based permissions
    ROLE_PERMISSIONS = {
      "provider" => %i[view_patients view_referrals create_referrals edit_own_referrals],
      "nurse" => %i[view_patients view_referrals update_referral_status],
      "clerk" => %i[view_patients view_referrals],
      "case_manager" => %i[view_patients view_referrals approve_referrals deny_referrals manage_referrals],
      "admin" => %i[view_patients view_referrals create_referrals approve_referrals deny_referrals manage_referrals],
      "user" => %i[view_own_referrals]
    }.freeze

    def self.permissions_for(user)
      ROLE_PERMISSIONS[user.user_type] || ROLE_PERMISSIONS["user"]
    end

    def self.can?(user, permission)
      permissions_for(user).include?(permission.to_sym)
    end

    # Aggregate all capabilities (role-based + key-derived) into a Set.
    def self.capabilities_for(user)
      caps = Set.new(permissions_for(user))

      caps << :approve_referrals if can_approve_chs?(user)
      caps << :deny_referrals if can_approve_chs?(user)
      caps << :process_claims if can_process_chs?(user)
      caps << :verify_eligibility if can_verify_eligibility?(user)
      caps << :manage_consults if can_manage_consults?(user)
      caps << :manage_scheduling if can_manage_scheduling?(user)
      caps << :access_behavioral_health if can_access_behavioral_health?(user)
      caps << :access_dental if can_access_dental?(user)

      caps
    end

    def self.has_key?(user, key_symbol)
      Array(user.security_keys).include?(key_symbol)
    end

    def self.has_any_key?(user, *key_symbols)
      keys = Array(user.security_keys)
      key_symbols.any? { |k| keys.include?(k) }
    end
  end
end
