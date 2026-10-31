# frozen_string_literal: true

require_relative "../shape"
require_relative "../mappings"
require_relative "../xwb_cipher"
require_relative "../context_scope"
require_relative "../reply"
require_relative "ddr_fileman"

module RpmsRpc
  # Symbolic API for VistA/RPMS authentication RPCs.
  # Underlying RPCs: XUS SIGNON SETUP, XUS AV CODE, XUS CVC,
  # XUS GET USER INFO, ORWU NPHASKEY, DDR LISTER. (The key
  # list once sent ORWU USERKEYS, a name no built 9.0 image registers, #207.
  # `user_security_keys` reads the user's KEYS multiple with DDR LISTER.
  # `held_keys` asks ORWU NPHASKEY once per named key, the batch bound to
  # OR CPRS GUI CHART. Over CIA the context rides on each frame, so N keys
  # cost N frames. Over XWB/BMX the cost is N when OR CPRS GUI CHART is
  # already bound, and N + 2 (a bind and a restore) otherwise.
  # `has_security_key?` asks about one key, through the same ORWU NPHASKEY.)
  module Authentication
    extend self
    extend Shape::Declarable

    ERROR_MESSAGES = {
      0 => nil,
      1 => "Invalid access/verify code",
      2 => "Logins inhibited",
      3 => "Account locked",
      4 => "Authentication failure",
      5 => "Other error",
      7 => "IP address locked (three-strike lockout)",
      12 => "Verify code expired - must be changed"
    }.freeze

    # ORWU USERINFO's USRCLS (piece 3) -> the sign-on result's user_type.
    # The server computes USRCLS from the user's order keys (ORWU.m:19):
    #   $S($D(^XUSEC("ORES",DUZ)):3,$D(^XUSEC("ORELSE",DUZ)):2,
    #      $D(^XUSEC("OREMAS",DUZ)):1,1:0)
    # Until #236 this table keyed 3/4/5 off XUS AV CODE line 5, which is the
    # post-sign-on message count, so everyone resolved to "user".
    USER_TYPES = {
      3 => "provider",
      2 => "nurse",
      1 => "clerk",
      0 => "user"
    }.freeze

    # The option that registers ORWU NPHASKEY for a chart session (rpms-rpc#521).
    HELD_KEYS_CONTEXT = "OR CPRS GUI CHART"

    # Sign on with an access/verify pair.
    #
    # The pair crosses the wire ENCRYPTED. XUSRB.VALIDAV always runs
    # $$DECRYP^XUSRB1 on its parameter, so a cleartext send reaches the broker
    # as garbage and a real RPMS rejects correct credentials (rpms-rpc#200).
    # The ciphertext goes as ONE parameter because it may contain "^".
    #
    # A successful result carries the sign-on facts only: DUZ, the message,
    # the verify flag and :post_signon_message_count (XUS AV CODE line 5,
    # which was read as a user class until #236). The user's class is a
    # separate read the host makes once it holds a context: #user_type.
    #
    # The whole sequence — SIGNON SETUP, AV CODE, and the user/key lookups it
    # implies — runs under the client's wire lock. The broker session these
    # RPCs read from is process-global state, so a second sign-on landing
    # between this one's AV CODE and its user lookup would hand this caller
    # the other clinician's name, role and security keys.
    def authenticate(access_code: nil, verify_code: nil)
      return validation_error("Access code is required") if blank?(access_code&.to_s&.strip)
      return validation_error("Verify code is required") if blank?(verify_code&.to_s&.strip)

      av_code = "#{normalize_code(access_code)};#{normalize_code(verify_code)}"

      with_wire_lock do
        # This attempt re-binds the broker session, so the client is nobody's
        # until it succeeds: a failed second sign-on must not leave the first
        # user's DUZ standing (auth_success sets it again).
        client = RpmsRpc.client
        client.clear_authenticated if client.respond_to?(:clear_authenticated)
        signon_setup
        parse_auth_response(DataMapper.av_code.fetch_lines(XwbCipher.encrypt(av_code)))
      end
    end

    def user_info(duz)
      return nil if invalid_id?(duz)

      # XUS GET USER INFO returns the authenticated session user's info
      # and takes no params; the duz arg is validated here only as an
      # API guard, not passed to the broker.
      info = DataMapper.user_info.fetch_lines
      return nil if info.nil? || info[:duz].to_i != duz.to_i

      info
    end
    shape :user_info, resource: "users", verb: "GET", path: "/users/{duz}/info"

    # The user_type for USRCLS, or nil for anything ORWU.m:19 does not return.
    def user_type_for(usrcls)
      text = usrcls.to_s.strip
      return nil unless text.match?(/\A\d+\z/)

      USER_TYPES[text.to_i]
    end

    # The signed-on user's class, as the server reports it: ORWU USERINFO
    # piece 3, USRCLS (ORWU.m:12-19), the same read CPRS makes. The gem does
    # not derive it from keys itself.
    #
    # A separate call, not part of #authenticate: ORWU USERINFO runs in the
    # context the session holds, and a fresh XWB session holds none, so the
    # host calls this after it binds its context (a CIA sign-on already holds
    # CIAV VUECENTRIC, which carries ORWU USERINFO).
    #
    # Returns "provider", "nurse", "clerk" or "user". Raises Client::RpcError
    # when the class cannot be read: the broker refused or failed the RPC,
    # answered nothing, answered for a different DUZ, or answered a USRCLS
    # that ORWU.m:19 never returns (the raw piece is checked, not a number
    # coerced from it). Never a default class: a host that asks provider?
    # must hear "unknown", not "no".
    # The user's idle limit in seconds: ORWU USERINFO's DTIME (piece 8), their own
    # TIMED READ (#200 200.1) or else the site default (#8989.3). How long RPMS
    # lets this user sit idle; a host that keeps the broker session open with
    # CiaClient#poll stops polling once it passes. nil when RPMS names none.
    def timed_read(duz)
      record = DataMapper.practitioner_info.fetch_one
      raise Client::RpcError, "ORWU USERINFO answered nothing" if record.nil?
      raise Client::RpcError, "ORWU USERINFO answered for another user, not DUZ #{duz}" unless record[:duz].to_i == duz.to_i

      Integer(record[:timed_read].to_s, exception: false)&.then { |s| s.positive? ? s : nil }
    end
    shape :timed_read, resource: "users", verb: "GET", path: "/users/{duz}/timed-read"

    def user_type(duz)
      record = DataMapper.practitioner_info.fetch_one
      raise Client::RpcError, "ORWU USERINFO answered nothing" if record.nil?
      unless record[:duz].to_i == duz.to_i
        raise Client::RpcError, "ORWU USERINFO answered for another user, not DUZ #{duz}"
      end

      usrcls = record[:usrcls]
      user_type_for(usrcls) ||
        raise(Client::RpcError, "ORWU USERINFO answered USRCLS #{usrcls.inspect}, which ORWU.m:19 never returns")
    end
    shape :user_type, resource: "users", verb: "GET", path: "/users/{duz}/type"

    # Whether user DUZ holds the security key KEY_NAME, per ORWU NPHASKEY
    # (any user, by DUZ). It used to send ORWU HASKEY both arguments, which
    # takes the key only, so a real server refused every call (#296).
    def has_security_key?(duz, key_name)
      return false if invalid_id?(duz) || blank_after_strip?(key_name)

      DataMapper.person_has_key.fetch_scalar(duz.to_s, key_name.to_s) == true
    end
    shape :has_security_key?, resource: "users", verb: "GET", path: "/users/{duz}/has-security-key"

    # The SECURITY KEY names user DUZ holds: the KEYS multiple of NEW PERSON
    # (#200 field 51, subfile 200.051), whose .01 KEY points to SECURITY KEY
    # #19.1, read with DDR LISTER (LIST^DIC; LISTC^DDR, DDR.m:6-27). FIELDS
    # "@;.01" returns IEN^KEY-name rows, the pointer in its external form.
    # DDR LISTER is in CIAV VUECENTRIC, the option sign-on binds, for a
    # programmer and a provider alike.
    #
    # Returns an Array of key names; [] for an invalid DUZ, and [] (no keys,
    # the least privilege) when the broker gives no reply or DDR reports an
    # error.
    def user_security_keys(duz)
      return [] if invalid_id?(duz)

      listed = DdrFileman.lister(file: "200.051", iens: ",#{duz},", fields: "@;.01")
      return [] if listed.nil? || listed[:error]

      listed[:entries].filter_map { |entry| presence(entry[:pieces].first) }
    end
    shape :user_security_keys, resource: "users", verb: "GET", path: "/users/{duz}/security-keys"

    # The subset of +names+ the signed-on user holds, in the order asked
    # (rpms-rpc#521). One ORWU NPHASKEY per name (NPHASKEY^ORWU(VAL,NP,KEY) =
    # ''$D(^XUSEC(KEY,NP))), NP the signed-on DUZ, the whole batch bound to
    # OR CPRS GUI CHART. Over CIA the context rides on each frame, so N keys
    # cost N frames. Over XWB/BMX the cost is N when OR CPRS GUI CHART is
    # already bound, and N + 2 (a bind and a restore) otherwise.
    #
    # Returns nil when the question could not be asked, so a consumer can tell
    # "holds none" ([]) from "could not ask" (nil): no signed-on DUZ (the
    # client has no #duz, or the DUZ is nil, blank, or non-positive), or any
    # one call refused (Client::RpcError), an altered reply, no data line,
    # more than one, or a line that is not exactly "0" or "1". The DUZ is
    # read inside the context scope, under the wire lock, and that one value
    # is NP for every call in the batch. An invalid DUZ returns nil from
    # there; the scope's ensure still restores the caller's context. Never a
    # partial list. Blank names are dropped; no names left sends nothing and
    # returns []. A name containing "^" or a leading "@" raises ArgumentError
    # before anything is sent.
    def held_keys(names)
      asked = Array(names).map { |name| name.to_s.strip }.reject(&:empty?)
      return [] if asked.empty?

      misread = asked.select { |name| name.include?("^") || name.start_with?("@") }
      raise ArgumentError, "not security key names: #{misread.join(', ')}" unless misread.empty?

      client = RpmsRpc.client
      flags = ContextScope.scoped(client, HELD_KEYS_CONTEXT) do
        duz = signed_on_duz(client)
        # Returns from held_keys. with_context's ensure still runs, so the
        # caller's context is restored.
        return nil if duz.nil?

        asked.map { |name| held_key_flag(client, duz, name) }
      end
      return nil if flags.any?(&:nil?)

      asked.each_index.select { |i| flags[i] == "1" }.map { |i| asked[i] }
    rescue Client::RpcError, Client::AuthenticationError
      # No signed-on session, or the bind/call was refused: the question
      # could not be asked. A not-authenticated bind raises before the block
      # reads the DUZ; that is the same nil as an invalid DUZ.
      nil
    end
    shape :held_keys, resource: "users", verb: "GET", path: "/users/held-keys"

    # The subset of option +names+ the signed-on user may run, in the order
    # asked, by Kernel's rule ($$ACCESS^XQCHK: on the user's primary or
    # secondary menu tree, not out of order, not locked by a key they lack).
    # One ORWU HAS OPTION ACCESS call per name.
    #
    # Returns nil when any call is refused or gives no 0/1 answer, so a
    # consumer can tell "may run none" ([]) from "could not ask" (nil). An
    # option that does not exist answers 0, like one the user may not run.
    def option_access(names)
      asked = Array(names).map { |name| name.to_s.strip }.reject(&:empty?)
      return [] if asked.empty?

      flags = asked.map { |name| option_access_flag(name) }
      return nil if flags.any?(&:nil?)

      asked.each_index.select { |i| flags[i] == "1" }.map { |i| asked[i] }
    end
    shape :option_access, resource: "users", verb: "GET", path: "/users/option-access"

    def change_verify_code(old_verify_code:, new_verify_code:, confirm_verify_code:, **_unused_keywords)
      return validation_error("Old verify code is required") if blank?(old_verify_code&.to_s&.strip)
      return validation_error("New verify code is required") if blank?(new_verify_code&.to_s&.strip)
      if blank?(confirm_verify_code&.to_s&.strip)
        return validation_error("Confirm verify code is required")
      end

      # CVC^XUSRB does NOT decrypt the way VALIDAV does. Read the M
      # (XUSRB.m:70-71): it SPLITS ON "^" FIRST, then decrypts each piece.
      #
      #   S U="^",XU2=$P(XU1,U,2),XU3=$P(XU1,U,3),XU1=$P(XU1,U)
      #   S XU1=$$DECRYP^XUSRB1(XU1),XU2=$$DECRYP^XUSRB1(XU2),XU3=$$DECRYP^XUSRB1(XU3)
      #
      # So each component is encrypted SEPARATELY and the ciphertexts are
      # joined with "^". Encrypting the whole triple as one value puts the
      # delimiter inside the ciphertext and the server decrypts three
      # fragments of garbage. (This framing is safe because the cipher table
      # deliberately omits "^" — see XwbCipher::TABLE — and verify codes
      # exclude it too, per AVHLPTXT^XUS2.)
      cvc_param = [
        normalize_code(old_verify_code),
        normalize_code(new_verify_code),
        normalize_code(confirm_verify_code)
      ].map { |component| XwbCipher.encrypt(component) }.join("^")

      parsed = with_wire_lock { DataMapper.cvc_verify.fetch_lines(cvc_param) }
      # `parsed&.dig(:result_code).to_i.zero?` was previously true for nil
      # responses (`nil.to_i == 0`), masking timeouts / RPC drops as success.
      # Require an explicit present `result_code` that equals `"0"`.
      code = parsed && parsed[:result_code]
      if code.to_s == "0"
        { success: true }
      else
        validation_error("Verify code change failed")
      end
    end

    # Retained for callers that clear state between tests. There is no longer
    # a cache to clear — see #signon_setup.
    def clear_cache!
      @signon_setup_cache = nil
    end

    private

    # Run a multi-RPC sequence as one uninterruptible unit on the shared
    # client. Reentrant, so nested calls that take the lock themselves are
    # safe. Delegates to RpmsRpc.synchronize_wire, which FAILS CLOSED (a
    # process-wide fallback lock) for a client that lacks its own wire lock —
    # never an unlocked yield.
    def with_wire_lock(&block)
      RpmsRpc.synchronize_wire(&block)
    end

    # XUS SIGNON SETUP establishes the partition the following AV CODE is
    # validated in, so it belongs to the SIGN-ON, not to the process.
    #
    # This used to be memoized in a module-level ivar. That cache outlived the
    # client it was populated for: a replaced client, or the same client after
    # a reconnect, is a NEW broker session, and the next authentication skipped
    # SETUP entirely and validated against a partition that was never set up.
    # A per-sign-on RPC is cheap; a sign-on against the wrong partition is not.
    def signon_setup
      DataMapper.signon_setup.fetch_scalar
    end

    # ORWU HAS OPTION ACCESS's one line, or nil. :user_option_access leaves
    # the line a string. Surrounding whitespace is dropped; only "0" or "1"
    # counts. A refused call (Client::RpcError), an empty reply, or any
    # other text is nil.
    def option_access_flag(name)
      flag = DataMapper.user_option_access.fetch_scalar(name).to_s.strip
      %w[0 1].include?(flag) ? flag : nil
    rescue Client::RpcError
      nil
    end

    # The signed-on DUZ to pass as NP, or nil when there is nothing to ask
    # with: the client has no #duz, or the DUZ is nil, blank, or not a
    # positive integer. Nothing is sent in that case.
    def signed_on_duz(client)
      return nil unless client.respond_to?(:duz)

      duz = client.duz
      return nil if invalid_id?(duz)

      duz.to_s.strip
    end

    # ORWU NPHASKEY's one data line, or nil. Ask Reply.altered? on the reply
    # object before normalising it, the same check Allergy and Patient.lookup
    # use for identity-bearing text. An altered reply is nil: CIA replaces a
    # control byte with a space and marks the reply, and ''$D() answers
    # exactly "0" or "1". Normalisation is :person_has_key's (trailing
    # $C(30)/$C(31) dropped; an Array also drops empty lines and recordset
    # header rows). Exactly one data line must remain, and that line must
    # equal "0" or "1". None, more than one, "2", "yes", " 1", "", or a
    # refused call is nil. The boolean coercion is not used. The client
    # numbers the frame; this does not touch its sequence counter.
    def held_key_flag(client, duz, name)
      reply = client.call_rpc(DataMapper.person_has_key.rpc_name, duz, name)
      return nil if Reply.altered?(reply)

      lines = DataMapper.person_has_key.normalized_lines(reply)
      return nil unless lines.size == 1

      flag = lines.first
      flag == "0" || flag == "1" ? flag : nil
    rescue Client::RpcError
      nil
    end

    def parse_auth_response(parsed)
      return validation_error("Invalid response") if parsed.nil? || parsed.empty?

      # A well-formed XUS AV CODE reply carries BOTH the DUZ (line 0) and a
      # NUMERIC error code (line 1). A missing OR non-numeric (e.g.
      # whitespace-only) error line is a short / malformed reply, NOT a
      # zero-error success: `nil.to_i == 0` and `" ".to_i == 0` would each
      # wave a positive DUZ through. Fail closed instead — the mapping keeps
      # this line raw precisely so the blank is still visible here.
      error_code_raw = parsed[:error_code].to_s.strip
      if parsed[:duz].nil? || !error_code_raw.match?(/\A-?\d+\z/)
        return validation_error("Invalid response")
      end

      duz = parsed[:duz].to_i
      error_code = error_code_raw.to_i
      verify_needs_change = parsed[:verify_needs_change].to_i == 1
      message = parsed[:message].to_s

      if duz.positive? && error_code.zero?
        auth_success(duz, message, verify_needs_change, parsed[:post_signon_message_count].to_i)
      else
        {
          success: false,
          duz: duz.positive? ? duz : nil,
          error: ERROR_MESSAGES[error_code] || presence(message) || "Authentication failed",
          error_code: error_code,
          verify_needs_change: error_code == 12
        }
      end
    end

    def auth_success(duz, message, verify_needs_change, post_signon_message_count)
      # The broker session is now this user's, so the client is signed on: a host
      # that signs on here binds its context next (create_context refuses a client
      # that is not). MockClient records the same DUZ; it has no such gate.
      # A stand-in that does not respond is left alone.
      client = RpmsRpc.client
      client.set_authenticated(duz.to_s) if client.respond_to?(:set_authenticated)

      result = {
        success: true,
        duz: duz,
        provider_ien: duz,
        message: message,
        verify_needs_change: verify_needs_change,
        # RET(5): how many post-sign-on message lines follow (XUSRB.m:86); 0
        # when the site suppresses the message (:87).
        post_signon_message_count: post_signon_message_count
      }

      info = user_info(duz)
      result[:name] = info[:name] if info
      result
    end

    def validation_error(message)
      { success: false, error: message }
    end

    def normalize_code(code)
      code.to_s.strip.upcase
    end

    def invalid_id?(value)
      return true if blank?(value)
      return false if value.is_a?(Integer) && value.positive?

      # Strict-digit guard: prevents inputs like "301abc" from sneaking
      # past to_i (which would return 301 and accidentally match the
      # session user via user_info's post-fetch duz comparison).
      !value.to_s.strip.match?(/\A[1-9]\d*\z/)
    end

    def presence(value)
      return nil if value.nil?

      str = value.to_s
      str.empty? ? nil : str
    end

    def blank?(value)
      value.nil? || value.to_s.empty?
    end

    def blank_after_strip?(value)
      value.nil? || value.to_s.strip.empty?
    end
  end
end
