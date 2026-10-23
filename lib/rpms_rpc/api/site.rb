# frozen_string_literal: true

require_relative "../shape"
require_relative "../mappings"

module RpmsRpc
  # Symbolic API for the authenticated user's current site. BEHOSICX SITEINFO
  # returns a single site (not a list) and takes no params; the duz arg is
  # an API-level guard, not a broker param.
  #
  # Note: site selection requires a different RPC path that BEHOSICX SITEINFO
  # does not implement — see rr-5tm for the tracking issue.
  module Site
    extend self
    extend Shape::Declarable

    def current(user_duz)
      return nil if invalid_duz?(user_duz)

      DataMapper.site_info.fetch_lines
    end
    shape :current, resource: "sites", verb: "GET", path: "/users/{user_duz}/sites/current"

    # Backward-compat: list-of-sites callers still expect an Array. Returns
    # [current] so existing iteration patterns keep working until callers
    # migrate to `current`.
    def list(user_duz)
      site = current(user_duz)
      site ? [ site ] : []
    end
    shape :list, resource: "sites", verb: "GET", path: "/users/{user_duz}/sites"

    private

    def invalid_duz?(value)
      value.nil? || value.to_s.strip.empty? || value.to_i <= 0
    end
  end
end
