# frozen_string_literal: true

require_relative "../shape"
require_relative "../mappings"

module RpmsRpc
  # Symbolic API for the cold-launch session bootstrap sequence.
  # Underlying RPCs: CIAVCXUS VIMINFO.
  #
  # It no longer reads CIAVMRPC GETPAR for "CIAVM DEFAULT SOURCE" (#239): that
  # value is the VueCentric client's own config root, which means nothing to a
  # consumer that is not that client. See the mapping file's note.
  #
  # It no longer calls CIAVMCFG GETREG (#522). That RPC dumps VueCentric's
  # widget registry (^CIAVOBJ) as ID=VALUE lines; a web app has no use for
  # it, and the result has no :registry key. See the mapping file's note.
  #
  # There is no :default_site_ien: VIMINFO answers DUZ^NAME^timeouts^compose^
  # design (CIAVCXUS.m:20-31) and names no site; the key read the DUZ (#221).
  module Session
    extend self
    extend Shape::Declarable

    def bootstrap(user_duz)
      return nil if invalid_duz?(user_duz)

      vim_info = DataMapper.session_vim_info.fetch_one(user_duz.to_s) || {}

      { vim_info: vim_info }
    end
    shape :bootstrap, resource: "sessions", verb: "GET", path: "/users/{user_duz}/sessions/bootstrap"

    private

    def invalid_duz?(value)
      value.nil? || value.to_s.strip.empty? || value.to_i <= 0
    end
  end
end
