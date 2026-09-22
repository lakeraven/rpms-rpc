# frozen_string_literal: true

# Aggregate entry point: core module state plus the reference tables consumers
# expect from `require "rpms_rpc/version"`. Clients require rpms_rpc/core
# directly — see core.rb for why.
require_relative "core"

require_relative "security_keys"
require_relative "user_roles"
require_relative "capabilities"
