# frozen_string_literal: true

require_relative "../mappings"

module RpmsRpc
  # Symbolic API for the cold-launch session bootstrap sequence.
  # Underlying RPCs: CIAVMRPC GETPAR, CIAVMCFG GETREG, CIAVCXUS VIMINFO.
  module Session
    extend self

    DEFAULT_SOURCE_PARAM = "CIAVM DEFAULT SOURCE"

    def bootstrap(user_duz)
      return nil if invalid_duz?(user_duz)

      config_root = DataMapper.session_default_source.fetch_scalar(DEFAULT_SOURCE_PARAM)
      registry    = DataMapper.session_registry.fetch_one || {}
      vim_info    = DataMapper.session_vim_info.fetch_one(user_duz.to_s) || {}

      {
        config_root: presence(config_root),
        registry: registry,
        vim_info: vim_info,
        default_site_ien: vim_info[:site_ien]
      }
    end

    private

    def invalid_duz?(value)
      value.nil? || value.to_s.strip.empty? || value.to_i <= 0
    end

    def presence(val)
      return nil if val.nil?

      str = val.to_s
      str.empty? ? nil : str
    end
  end
end
