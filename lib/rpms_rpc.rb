# frozen_string_literal: true

# The gem's entry point: `require "rpms_rpc"` loads the public API.
#
# - core: configuration (`configure`, `client`, `mock!`, `reset!`), the wire
#   lock and error sanitizing. It lives in its own file because a single
#   broker client (`require "rpms_rpc/cia_client"`) needs it without the rest.
# - the reference tables: security keys, user roles, capabilities.
# - the response mappings, and every symbolic API module under rpms_rpc/api/.
#
# Broker clients are not loaded here: pick one with RpmsRpc::BrokerFactory or
# require it directly. MockClient loads on `RpmsRpc.mock!`.
require_relative "rpms_rpc/version"
require_relative "rpms_rpc/core"
require_relative "rpms_rpc/data_mapper"
require_relative "rpms_rpc/mappings"
require_relative "rpms_rpc/security_keys"
require_relative "rpms_rpc/user_roles"
require_relative "rpms_rpc/capabilities"

Dir[File.join(__dir__, "rpms_rpc", "api", "**", "*.rb")].sort.each { |api| require api }
