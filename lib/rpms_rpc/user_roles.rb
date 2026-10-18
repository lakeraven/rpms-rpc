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
    # DEPRECATED (#359): warns once per process. Answers are unchanged.
    def self.for_class(user_class)
      warn_deprecated(:for_class)
      class_name_for(user_class)
    end

    # Return the user_class string for a role (e.g., "provider" → "3").
    # DEPRECATED (#359): warns once per process. Answers are unchanged.
    def self.class_for(role)
      warn_deprecated(:class_for)
      class_number_for(role)
    end

    # Return mock-friendly av_code attrs for a role. Caller mocks/seeds
    # this into the XUS AV CODE response so role-resolution drives off
    # the correct field. user_class is an Integer to match the av_code
    # mapping's `line_field 5, :user_class, :integer` coercion.
    # DEPRECATED (#359): warns once per process. Answers are unchanged.
    # Uses class_number_for so this does not also warn as class_for.
    def self.mock_av_code(duz:, role:)
      warn_deprecated(:mock_av_code)
      { duz: duz.to_i, error_code: 0, verify_needs_change: 0,
        message: "", user_class: (class_number_for(role) || "0").to_i }
    end

    # Determine role from the auth-class user_class (av_code line 5,
    # captured at signon time — NOT user_info[:user_class_ien] which
    # points into USER CLASS file #8932.1) plus security keys.
    #
    # Security keys can elevate a role above what user_class alone
    # implies (e.g., PRCFA SUPERVISOR → case_manager).
    #
    # DEPRECATED elevation: :prc_supervisor and :prc_manager stood for
    # PRCFA SUPERVISOR and BPRC MANAGER, which are not security keys on the
    # pinned build (#314), so no signed-on user's keys carry them. It is kept
    # because a host that builds its own key list still relies on it; roles
    # leave the gem in #359 (ADR 0010: the host decides policy).
    #
    # Warns once per process; answers are unchanged. Uses class_name_for so
    # this does not also warn as for_class.
    def self.resolve(user_class:, security_keys:)
      warn_deprecated(:resolve)
      if security_keys.include?(:prc_supervisor) || security_keys.include?(:prc_manager)
        return "case_manager"
      end

      class_name_for(user_class)
    end

    # Non-warning path. resolve calls this so one resolve does not also warn
    # as for_class.
    def self.class_name_for(user_class)
      USER_CLASS_MAP[user_class.to_s] || "user"
    end
    private_class_method :class_name_for

    # Non-warning path. mock_av_code calls this so one mock_av_code does not
    # also warn as class_for.
    def self.class_number_for(role)
      REVERSE_CLASS_MAP[role.to_s]
    end
    private_class_method :class_number_for

    @deprecation_warned = {}
    @deprecation_lock = Mutex.new

    # Public methods call this directly. uplevel 2 attributes the warning to
    # their caller (the host), not to a frame in this file.
    def self.warn_deprecated(method)
      first = @deprecation_lock.synchronize { !@deprecation_warned.key?(method) && (@deprecation_warned[method] = true) }
      return unless first

      warn "[rpms_rpc] DEPRECATED: RpmsRpc::UserRoles.#{method} is role vocabulary in the gem. " \
           "It will be removed (#359). Read the keys a user holds (#318) and decide policy in the host (ADR 0010).",
           uplevel: 2
    end
    private_class_method :warn_deprecated

    # For tests: let each deprecated method warn again.
    def self.reset_deprecation_warnings!
      @deprecation_lock.synchronize { @deprecation_warned.clear }
    end
  end
end
