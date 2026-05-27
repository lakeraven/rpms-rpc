# frozen_string_literal: true

require_relative "../mappings"

module RpmsRpc
  # Symbolic API for site/division context. A user may have access to several
  # divisions; one is selected at any given moment and scopes downstream RPCs.
  # Underlying RPC: BEHOSICX SITEINFO.
  module Site
    extend self

    def list(user_duz)
      return [] if invalid_duz?(user_duz)

      Array(DataMapper.site_info.fetch_many(user_duz.to_s))
    end

    def current(user_duz)
      list(user_duz).find { |site| site[:current] }
    end

    def select(user_duz, site_ien)
      return false if invalid_duz?(user_duz) || invalid_ien?(site_ien)

      RpmsRpc.client.call_rpc(DataMapper.site_info.rpc_name, user_duz.to_s, site_ien.to_s)
      true
    end

    private

    def invalid_duz?(value)
      value.nil? || value.to_s.strip.empty? || value.to_i <= 0
    end

    def invalid_ien?(value)
      value.nil? || value.to_s.strip.empty? || value.to_i <= 0
    end
  end
end
