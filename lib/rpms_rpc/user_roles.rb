# frozen_string_literal: true

module RpmsRpc
  module UserRoles
    USER_CLASS_MAP = {
      "1" => "admin",
      "3" => "provider",
      "4" => "nurse",
      "5" => "clerk"
    }.freeze

    REVERSE_CLASS_MAP = USER_CLASS_MAP.invert.freeze

    # Resolve a VistA user class number to a role string.
    def self.for_class(user_class)
      USER_CLASS_MAP[user_class.to_s] || "user"
    end

    # Return the user_class string for a role (e.g., "provider" → "3").
    def self.class_for(role)
      REVERSE_CLASS_MAP[role.to_s]
    end

    # Return mock-friendly av_code attrs for a role. Caller mocks/seeds
    # this into the XUS AV CODE response so role-resolution drives off
    # the correct field.
    def self.mock_av_code(duz:, role:)
      { duz: duz.to_i, error_code: 0, verify_needs_change: 0,
        message: "", user_class: class_for(role) || "0" }
    end

    # Determine role from the auth-class user_class (av_code line 5,
    # captured at signon time — NOT user_info[:user_class_ien] which
    # points into USER CLASS file #8932.1) plus security keys.
    #
    # Security keys can elevate a role above what user_class alone
    # implies (e.g., PRCFA SUPERVISOR → case_manager).
    def self.resolve(user_class:, security_keys:)
      if security_keys.include?(:prc_supervisor) || security_keys.include?(:prc_manager)
        return "case_manager"
      end

      for_class(user_class)
    end
  end
end
