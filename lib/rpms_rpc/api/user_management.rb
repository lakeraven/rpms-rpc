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

      user_info = DataMapper.user_info.fetch_one(duz.to_s)
      return nil if user_info.nil?

      {
        user_info: user_info,
        practitioner: DataMapper.practitioner_info.fetch_one(duz.to_s, extras: { ien: duz }),
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
      DataMapper.user_keys.fetch_many(duz.to_s).filter_map { |row| presence(row[:key_name]) }
    end

    def change_key(mapping_name, duz, key_name, verb, preposition, fallback)
      duz = normalize_duz(duz)
      return { success: false, error: "Invalid DUZ" } if duz.nil?

      key_name = key_name.to_s.strip
      return { success: false, error: "Key name required" } if key_name.empty?

      mapping = DataMapper[mapping_name]
      response = RpmsRpc.client.call_rpc(mapping.rpc_name, duz.to_s, key_name)
      first_line = response.is_a?(Array) ? response.first.to_s : response.to_s
      parsed = mapping.parse_one(first_line)

      if parsed&.fetch(:success, false)
        { success: true, message: "Key #{key_name} #{verb} #{preposition} DUZ #{duz}" }
      else
        error = presence(parsed && parsed[:message]) || fallback
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
