# frozen_string_literal: true

require_relative "../mappings"

module RpmsRpc
  # Symbolic API for the cold-launch session bootstrap sequence.
  # Underlying RPCs: CIAVMCFG GETREG, CIAVCXUS VIMINFO.
  #
  # It no longer reads CIAVMRPC GETPAR for "CIAVM DEFAULT SOURCE" (#239): that
  # value is the VueCentric client's own config root, which means nothing to a
  # consumer that is not that client. See the mapping file's note.
  #
  # There is no :default_site_ien: VIMINFO answers DUZ^NAME^timeouts^compose^
  # design (CIAVCXUS.m:20-31) and names no site; the key read the DUZ (#221).
  module Session
    extend self

    def bootstrap(user_duz)
      return nil if invalid_duz?(user_duz)

      registry = DataMapper.session_registry.fetch_one || {}
      vim_info = DataMapper.session_vim_info.fetch_one(user_duz.to_s) || {}

      {
        registry: registry,
        vim_info: vim_info
      }
    end

    private

    def invalid_duz?(value)
      value.nil? || value.to_s.strip.empty? || value.to_i <= 0
    end
  end
end
