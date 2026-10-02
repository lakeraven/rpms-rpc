# frozen_string_literal: true

module RpmsRpc
  # A user's role, derived from the security keys RPMS holds for them.
  #
  # Keys are the ONLY source. No sign-on reply carries a user class:
  # VALIDAV^XUSRB returns DUZ, XUM, VCCH, message, 0 and the post-sign-on
  # message count (XUSRB.m:9-11, :40, :85-87); USERINFO^XUSRB2 returns name,
  # division, title, service/section, language and DTIME (XUSRB2.m:25-35).
  # The one "user class" CPRS reports — USRCLS, piece 3 of ORWU USERINFO — is
  # itself computed from keys on the server (ORWU.m:19):
  #
  #   S $P(REC,U,3)=$S($D(^XUSEC("ORES",DUZ)):3,$D(^XUSEC("ORELSE",DUZ)):2,
  #                    $D(^XUSEC("OREMAS",DUZ)):1,1:0)
  #
  # so resolve follows the same precedence. Until #236 this module mapped a
  # number read from av_code line 5 — the message count — through an invented
  # 1/3/4/5 code table; that vocabulary is gone.
  module UserRoles
    # Order-authority keys in ORWU.m:19's precedence, and the role each names.
    # ORES signs orders (providers); ORELSE releases them (nurses and other
    # clinicians); OREMAS enters them for signature (clerks).
    ORDER_KEY_ROLES = [
      [ :ores,   "provider" ],
      [ :orelse, "nurse" ],
      [ :oremas, "clerk" ]
    ].freeze

    # Keys that elevate any order role to case_manager.
    ELEVATING_KEYS = %i[prc_supervisor prc_manager].freeze

    # security_keys: symbols from SecurityKeys.symbolize.
    def self.resolve(security_keys:)
      keys = Array(security_keys).map(&:to_sym)
      return "case_manager" if keys.intersect?(ELEVATING_KEYS)

      ORDER_KEY_ROLES.each { |key, role| return role if keys.include?(key) }
      "user"
    end
  end
end
