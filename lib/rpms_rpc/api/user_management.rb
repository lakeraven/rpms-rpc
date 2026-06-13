# frozen_string_literal: true

module RpmsRpc
  # Symbolic API for New Person / user-management operations.
  # Underlying RPCs: ORWU NEWPERS, XUS GET USER INFO, ORWU USERKEYS, XU KEY*.
  module UserManagement
    extend self

    def search(name_pattern)
      pattern = name_pattern.to_s.strip
      return [] if pattern.empty?

      DataMapper.user_management_user_list.fetch_many(pattern, "1")
    end

    def find(duz)
      duz = normalize_duz(duz)
      return nil if duz.nil?

      # Both ORWU USERINFO and XUS GET USER INFO return info about the
      # AUTHENTICATED session user — neither RPC accepts a DUZ param.
      # Passing one to ORWU USERINFO raises <PARAMETER>. So find(duz)
      # can only succeed when duz matches the session user; arbitrary-
      # DUZ lookup would need a different RPC (BHDPTRPC / DDR LISTER /
      # direct File 200 read) that isn't currently mapped.
      user_info = DataMapper.user_info.fetch_lines
      return nil if user_info.nil? || user_info[:duz].to_i != duz

      practitioner = DataMapper.practitioner_info.fetch_one
      return nil if practitioner.nil? || practitioner[:duz].to_i != duz

      {
        user_info: user_info,
        practitioner: practitioner,
        security_keys: security_keys(duz).sort
      }
    end

    def grant_key(duz, key_name)
      change_key(:key_grant, duz, key_name, "granted", "to", "Grant failed")
    end

    def revoke_key(duz, key_name)
      change_key(:key_revoke, duz, key_name, "revoked", "from", "Revoke failed")
    end

    def list_all_keys
      DataMapper.key_list.fetch_many
    end

    private

    def security_keys(duz)
      return [] unless RpmsRpc.client.supports?(:user_security_keys_list)

      DataMapper.user_keys.fetch_many(duz.to_s).filter_map { |row| presence(row[:key_name]) }
    end

    def change_key(mapping_name, duz, key_name, verb, preposition, fallback)
      duz = normalize_duz(duz)
      return { success: false, error: "Invalid DUZ" } if duz.nil?

      key_name = key_name.to_s.strip
      return { success: false, error: "Key name required" } if key_name.empty?

      rpc_name = DataMapper[mapping_name].rpc_name
      response = RpmsRpc.client.call_rpc(rpc_name, duz.to_s, key_name)
      first_line = response.is_a?(Array) ? response.first.to_s : response.to_s

      # Gateway behavior: success when the first line starts with "1" (handles
      # both "1", "1^message", and "1Some text" forms). Failure path strips a
      # leading "0" or "0^" prefix to surface the actual error text from RPMS
      # — e.g. "0No such key" → "No such key" — rather than masking it with
      # the generic fallback.
      if first_line.start_with?("1")
        { success: true, message: "Key #{key_name} #{verb} #{preposition} DUZ #{duz}" }
      else
        error = presence(first_line.sub(/\A0\^?/, "")) || fallback
        { success: false, error: error }
      end
    end

    def normalize_duz(duz)
      return nil if duz.nil?

      str = duz.to_s.strip
      return nil unless str.match?(/\A[1-9]\d*\z/)

      str.to_i
    end

    def presence(val)
      return nil if val.nil?

      str = val.to_s.strip
      str.empty? ? nil : str
    end
  end
end
