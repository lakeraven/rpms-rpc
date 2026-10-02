# frozen_string_literal: true

module RpmsRpc
  # Symbolic API for New Person / user-management operations.
  # Underlying RPCs: ORWU NEWPERS, XUS GET USER INFO, ORWU USERINFO.
  #
  # The key-management methods this module once offered (`grant_key`,
  # `revoke_key`, `list_all_keys`, and the `security_keys` list inside
  # `find`) sent XU KEY GRANT / REVOKE / LIST and ORWU USERKEYS, names no
  # built 9.0 image registers; they were removed (#207). Per-key checks
  # remain on the registered ORWU HASKEY (Authentication.has_security_key?).
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
      # DUZ lookup would need a different RPC (DDR LISTER / direct
      # File 200 read) that isn't currently mapped.
      user_info = DataMapper.user_info.fetch_lines
      return nil if user_info.nil? || user_info[:duz].to_i != duz

      practitioner = DataMapper.practitioner_info.fetch_one
      return nil if practitioner.nil? || practitioner[:duz].to_i != duz

      {
        user_info: user_info,
        practitioner: practitioner
      }
    end

    private

    def normalize_duz(duz)
      return nil if duz.nil?

      str = duz.to_s.strip
      return nil unless str.match?(/\A[1-9]\d*\z/)

      str.to_i
    end
  end
end
