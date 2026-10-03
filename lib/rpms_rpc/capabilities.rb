# frozen_string_literal: true

require_relative "mappings"

module RpmsRpc
  # Framework-agnostic capability checks derived from RPMS security keys.
  # Used by authorization policies in any engine (Pundit, Action Policy, etc.).
  #
  # All methods accept a user-like object that responds to:
  #   - security_keys: Array of symbols (e.g., [:scheduling_admin, :registration_manager])
  #   - user_type: String (e.g., "provider", "nurse")
  #
  # (An RPC-backed `imaging_user?` once lived here on MAGGUSERKEYS, a name
  # no built 9.0 image registers; it was removed, #207. The registered
  # imaging key check is MAGGDUZKEY.)
  module Capabilities
    # Seven checks test symbols whose key names are not SECURITY KEYs (#19.1)
    # on the pinned build (#314), so no signed-on user can hold them and the
    # checks answer true only for a user object a host built by hand. They are
    # DEPRECATED, not removed: removing a method is a breaking change (ADR 0010
    # rule 10), and their removal is #359's job, after a release that warns.
    # Each warns once per process when called; what it answers is unchanged.
    #
    # check => [the symbols it tests, the names those symbols stood for]
    DEPRECATED_CHECKS = {
      can_approve_chs?: [ %i[prc_supervisor prc_manager], [ "PRCFA SUPERVISOR", "BPRC MANAGER" ] ],
      can_process_chs?: [ %i[prc_tech prc_supervisor], [ "PRCFA TECH", "PRCFA SUPERVISOR" ] ],
      can_manage_chs?: [ %i[prc_supervisor prc_tech prc_manager chs_approve chs_clerk],
                         [ "PRCFA SUPERVISOR", "PRCFA TECH", "BPRC MANAGER", "BGOZ CHS APPROVE", "BGOZ CHS CLERK" ] ],
      can_manage_consults?: [ %i[consult_manager], [ "GMRC MGR" ] ],
      can_verify_eligibility?: [ %i[eligibility_verify], [ "APCL VERIFY" ] ],
      can_access_behavioral_health?: [ %i[bh_provider bh_supervisor], [ "BGMH PROVIDER", "BGMH SUPERVISOR" ] ],
      can_access_dental?: [ %i[dental_provider dental_supervisor], [ "DENTP PROVIDER", "DENTP SUPERVISOR" ] ]
    }.freeze

    DEPRECATED_CHECKS.each_key do |check|
      define_singleton_method(check) do |user|
        warn_deprecated(check)
        deprecated_check(check, user)
      end
    end

    def self.can_manage_scheduling?(user)
      has_key?(user, :scheduling_admin)
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

      # The deprecated checks still feed these, without warning: a host that
      # reads capabilities_for gets what it got before (#314; removal is #359).
      caps << :approve_referrals if deprecated_check(:can_approve_chs?, user)
      caps << :deny_referrals if deprecated_check(:can_approve_chs?, user)
      caps << :process_claims if deprecated_check(:can_process_chs?, user)
      caps << :verify_eligibility if deprecated_check(:can_verify_eligibility?, user)
      caps << :manage_consults if deprecated_check(:can_manage_consults?, user)
      caps << :manage_scheduling if can_manage_scheduling?(user)
      caps << :access_behavioral_health if deprecated_check(:can_access_behavioral_health?, user)
      caps << :access_dental if deprecated_check(:can_access_dental?, user)

      caps
    end

    def self.deprecated_check(check, user)
      has_any_key?(user, *DEPRECATED_CHECKS.fetch(check).first)
    end
    private_class_method :deprecated_check

    @deprecation_warned = {}
    @deprecation_lock = Mutex.new

    def self.warn_deprecated(check)
      first = @deprecation_lock.synchronize { !@deprecation_warned.key?(check) && (@deprecation_warned[check] = true) }
      return unless first

      names = DEPRECATED_CHECKS.fetch(check).last.join(", ")
      warn "[rpms_rpc] DEPRECATED: RpmsRpc::Capabilities.#{check} tests names that are " \
           "not a security key on the pinned build (#314), so no signed-on user holds them: #{names}. " \
           "It will be removed (#359). Read the keys a user holds (#318) and decide policy in the host (ADR 0010).",
           uplevel: 2
    end
    private_class_method :warn_deprecated

    # For tests: let each deprecated check warn again.
    def self.reset_deprecation_warnings!
      @deprecation_lock.synchronize { @deprecation_warned.clear }
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
