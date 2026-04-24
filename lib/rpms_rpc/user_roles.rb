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

    # Return mock-friendly user_info attrs for a role.
    def self.mock_user_info(duz:, name:, role:)
      is_provider = (role.to_s == "provider")
      user_class = class_for(role) || "0"
      { duz: duz.to_i, name: name, user_class: user_class,
        can_sign: is_provider, is_provider: is_provider, order_role: is_provider ? "1" : "" }
    end

    # Determine role from user info and security keys.
    # Security keys can elevate a role (e.g., PRCFA SUPERVISOR → case_manager).
    def self.resolve(user_info:, security_keys:)
      return "provider" if user_info&.dig(:is_provider)

      if security_keys.include?(:prc_supervisor) || security_keys.include?(:prc_manager)
        return "case_manager"
      end

      for_class(user_info&.dig(:user_class))
    end
  end
end
