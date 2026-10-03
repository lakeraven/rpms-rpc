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
  # `imaging_user?` is RPC-backed and requires only `duz` on the user object.
  #
  module Capabilities
    # Each check names a SECURITY KEY on a built image (SecurityKeys). The
    # CHS, consult, eligibility, behavioral health and dental checks were
    # removed in #314: the names they tested are not keys on the image.
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

      caps << :manage_scheduling if can_manage_scheduling?(user)

      caps
    end

    def self.has_key?(user, key_symbol)
      Array(user.security_keys).include?(key_symbol)
    end

    def self.has_any_key?(user, *key_symbols)
      keys = Array(user.security_keys)
      key_symbols.any? { |k| keys.include?(k) }
    end

    # Imaging access — probed on every chart open. Backed by MAGGUSERKEYS;
    # cached per user_duz since imaging keys don't change mid-session.
    def self.imaging_user?(user)
      duz = user.respond_to?(:duz) ? user&.duz : nil
      return false if duz.nil? || duz.to_s.strip.empty?

      key = duz.to_s
      @imaging_cache ||= {}
      return @imaging_cache[key] if @imaging_cache.key?(key)

      keys = Array(DataMapper.imaging_user_keys.fetch_many(key))
      @imaging_cache[key] = keys.any? { |row| !row[:key_name].to_s.strip.empty? }
    end

    def self.clear_imaging_cache!
      @imaging_cache = {}
    end
  end
end
