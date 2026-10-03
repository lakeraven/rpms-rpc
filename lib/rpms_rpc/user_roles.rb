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
    # the correct field. user_class is an Integer to match the av_code
    # mapping's `line_field 5, :user_class, :integer` coercion.
    def self.mock_av_code(duz:, role:)
      { duz: duz.to_i, error_code: 0, verify_needs_change: 0,
        message: "", user_class: (class_for(role) || "0").to_i }
    end

    # Determine role from the auth-class user_class (av_code line 5,
    # captured at signon time — NOT user_info[:user_class_ien] which
    # points into USER CLASS file #8932.1). No key elevates the role: the
    # keys that did (PRCFA SUPERVISOR, BPRC MANAGER) are not keys on a built
    # image (#314). security_keys is kept for callers' signatures.
    def self.resolve(user_class:, security_keys: [])
      for_class(user_class)
    end
  end
end
