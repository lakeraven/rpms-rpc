# frozen_string_literal: true

require_relative "core"

module RpmsRpc
  # The roles a live spec signs on as, the way an app's tests sign on as Admin
  # or Org Manager: `runs_as :provider`, `runs_as :scheduler`. A role is named
  # for the clinic persona it plays (openrpms-ux docs/product-cycle/PERSONAS.md),
  # and its row says everything about the RPMS account behind it, once: the
  # NEW PERSON entry, its sign-on pair, its electronic signature code, the
  # broker options its RPCs may run under, its keys, and whether it holds
  # XUPROGMODE. Nothing else in the repository repeats them: the live harness,
  # the daily report, the wire captures and CI all read this table.
  #
  # The accounts are the openrpms build's published demo users (SEEDPERS) on
  # synthetic data, so their pairs are published here, as the build publishes
  # them. The operator's pair is the -demo image's development credential
  # (openrpms README, quick start: SYS123 / RPMS.000); a base or deployed image
  # sets its own, and a run against one names it in RPMS_ACCESS / RPMS_VERIFY.
  #
  # Least privilege means each row is minimal: the role holds what its
  # persona's work needs and no more. test/live/role_refusal_live_test.rb proves
  # every row against the build (answered where the row says the role holds an
  # option, refused everywhere else), and the harness fails a run whose
  # signed-on account's XUPROGMODE disagrees with its row, so an operator
  # sign-on cannot pass for another role and hide a permission gap.
  #
  # The rows are what bcer-9.0-20261124-60d39b6-ydb seeds (its personas.json),
  # with the options each role is answered in as observed by the refusal spec
  # on that release. A pending row is instead what its openrpms issue seeds,
  # until a release carries it. When the release adds a `role` field to
  # personas.json, these rows can be read from it instead.
  module TestRoles
    # ROLE names no test role.
    class UnknownRole < RpmsRpc::Error; end

    # contexts: the broker options (context options) the role's RPCs may run
    # under, whether a secondary menu or reached through its primary menu.
    # A holder of XUPROGMODE is answered under every option, so its list is empty.
    # pending: the openrpms issue that seeds the role's account, while no
    # release carries it yet. Until then the account is on no build, so the
    # role holds nothing there and a spec that `needs` an option skips by its
    # tracked issue; nil once a release carries it.
    Role = Data.define(:name, :persona, :account, :access, :verify, :esig, :contexts, :keys, :xuprogmode, :pending) do
      def initialize(pending: nil, **fields) = super

      # Whether the broker answers this role's RPCs under the option.
      def holds?(option) = pending.nil? && (xuprogmode || contexts.include?(option.to_s))

      # [access, verify]; verify is nil for a role whose code is not published.
      def pair = [ access, verify ]
    end

    CLINICAL_CONTEXTS = [ "CIAV VUECENTRIC", "BMXRPC", "BSDXRPC", "BSTSRPC" ].freeze
    REGISTRATION_CONTEXTS = [ "CIAV VUECENTRIC", "AGGRPC", "BMXRPC", "BSDXRPC" ].freeze

    ROLES = [
      Role.new(name: :provider, persona: "provider", account: "PROFILE,MD",
               access: "PMD123", verify: "PMD123!!", esig: "123456",
               contexts: (CLINICAL_CONTEXTS + [ "BMCRPC", "OR CPRS GUI CHART", "XQAL GUI ALERTS" ]).freeze,
               keys: %w[PROVIDER ORES BMCZMENU].freeze, xuprogmode: false),
      Role.new(name: :nurse, persona: "nurse", account: "PROFILE,RN",
               access: "PRN123", verify: "PRN123!!", esig: "123456",
               contexts: CLINICAL_CONTEXTS, keys: %w[PROVIDER ORELSE].freeze, xuprogmode: false),
      Role.new(name: :medical_assistant, persona: "medical_assistant", account: "PROFILE,MA",
               access: "PMA123", verify: "PMA123!!", esig: "123456",
               contexts: CLINICAL_CONTEXTS, keys: %w[PROVIDER OREMAS].freeze, xuprogmode: false),
      Role.new(name: :front_desk_clerk, persona: "front_desk_clerk", account: "PROFILE,REG",
               access: "PREG123", verify: "PREG123!!", esig: nil,
               contexts: REGISTRATION_CONTEXTS, keys: %w[AGZMENU].freeze, xuprogmode: false),
      Role.new(name: :registration_supervisor, persona: "registration_supervisor", account: "PROFILE,REGSUP",
               access: "PRSUP123", verify: "PRSUP123!!", esig: nil,
               contexts: REGISTRATION_CONTEXTS, keys: [ "AGZMENU", "AGZMGR", "AGZVIEWSSN", "DGPF ASSIGNMENT" ].freeze,
               xuprogmode: false),
      Role.new(name: :scheduler, persona: "scheduler", account: "PROFILE,SCHED",
               access: "PSCH123", verify: "PSCH123!!", esig: nil,
               contexts: REGISTRATION_CONTEXTS, keys: %w[SDZMENU SDZREGMENU].freeze, xuprogmode: false),
      # The behavioral health provider, a licensed clinical social worker, the
      # BH clinic's provider: the Behavioral Health System's primary menu
      # AMHMENU, its keys AMHZMENU and AMHZ DATA ENTRY, and the BH GUI's context
      # AMHGRPC; openrpms#1299 moved behavioral health off the provider, and
      # bcer-9.0-20261124-60d39b6-ydb is the first release that carries it.
      Role.new(name: :bh_provider, persona: "bh_provider", account: "PROFILE,BH",
               access: "PBH123", verify: "PBH123!!", esig: "123456",
               contexts: [ "CIAV VUECENTRIC", "BMXRPC", "AMHGRPC" ].freeze,
               keys: [ "PROVIDER", "AMHZMENU", "AMHZ DATA ENTRY" ].freeze, xuprogmode: false),
      # Roll-and-scroll only: no CIAV VUECENTRIC, so no broker signs it on.
      Role.new(name: :billing_technician, persona: "billing_technician", account: "PROFILE,BILL",
               access: "PBIL123", verify: "PBIL123!!", esig: nil,
               contexts: [].freeze, keys: [ "ABMZMENU", "ABMDZ EDIT CLAIM AND EXPORT", "BARZMENU" ].freeze,
               xuprogmode: false),
      # The Admin: the build's operator, and the only role that holds XUPROGMODE.
      Role.new(name: :operator, persona: nil, account: "MANAGER,SYSTEM",
               access: "SYS123", verify: "RPMS.000", esig: "123456",
               contexts: [].freeze, keys: %w[XUPROGMODE].freeze, xuprogmode: true)
    ].to_h { |role| [ role.name, role ] }.freeze

    # The demo accounts the suite once named by access code, before roles: what
    # to set instead. PROV123 (PROVIDER,TEST) is no test role; it stays a
    # stack's staging sign-on, and its specs run as the provider.
    RETIRED_PERSONAS = {
      "PROV123" => :provider, "PMD123" => :provider, "PREG123" => :front_desk_clerk,
      "PSCH123" => :scheduler, "SYS123" => :operator
    }.freeze

    module_function

    def names = ROLES.keys

    # The role named NAME (a symbol or a string), or nil.
    def [](name)
      ROLES[name.to_s.strip.to_sym] unless name.to_s.strip.empty?
    end

    def fetch(name)
      self[name] || raise(UnknownRole, unknown_message(name))
    end

    def unknown_message(name)
      "ROLE=#{name.to_s.inspect} is not a test role: one of #{names.join(', ')} (README, Test roles)"
    end

    # The access code of every role, the accounts a capture may sign on as.
    def access_codes = ROLES.values.map(&:access)

    # The role whose account signs on with this access code, or nil.
    def for_access(access)
      ROLES.values.find { |role| role.access == access.to_s }
    end

    # What to tell someone whose environment still names the old PERSONA, or
    # nil when PERSONA is unset. It never keeps working under the old name.
    def retired_persona_message(env = ENV)
      old = env["PERSONA"].to_s.strip
      return nil if old.empty?

      role = RETIRED_PERSONAS[old]
      hint = role ? "set ROLE=#{role}" : "set ROLE to one of #{names.join(', ')}"
      "PERSONA=#{old} is retired: a live run signs on as a role. Unset PERSONA and #{hint} (README, Test roles)"
    end

    # nil when the account's XUPROGMODE agrees with the role's row, else why not.
    def xuprogmode_mismatch(role, holds:)
      return nil if holds == role.xuprogmode

      if holds
        "the account signed on as #{role.name} holds XUPROGMODE, which its row does not give it: " \
          "every option answers a programmer, so the run would hide a permission gap. " \
          "Sign on with #{role.name}'s own pair (#{role.account})"
      else
        "the account signed on as #{role.name} does not hold XUPROGMODE, which its row says it holds. " \
          "Sign on with #{role.name}'s own pair (#{role.account})"
      end
    end
  end
end
