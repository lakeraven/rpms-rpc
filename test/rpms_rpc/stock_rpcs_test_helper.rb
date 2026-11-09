# frozen_string_literal: true

require "json"
require "rpms_rpc/conformance/inventory_lock"

# The #420 stock specs ask an array for its one element (.sole). This Ruby
# has no Enumerable#sole; this is that check, for the specs that load this helper.
unless Enumerable.method_defined?(:sole)
  module Enumerable
    def sole
      items = to_a
      raise ArgumentError, "expected exactly one element, got #{items.size}" unless items.size == 1

      items.first
    end
  end
end

# Shared pins for rpms-rpc#420 stock-RPC wrapper tests (pinned bcer-9.0 build).
module StockRpcsTestHelper
  ROOT = File.expand_path("../..", __dir__)
  PINNED_TAG = "bcer-9.0-20261012-e7923a4-ydb"
  INVENTORIES_DIR = File.join(ROOT, "data/inventories")
  REQUIRED_RPCS_PATH = File.join(ROOT, "lib/rpms_rpc/required_rpcs.json")

  module_function

  def pinned_surface
    @pinned_surface ||= RpmsRpc::Conformance::InventoryLock
      .load(File.join(ROOT, "data/fingerprints/rpms-ops.lock.yml"))
      .surfaces(inventories_dir: INVENTORIES_DIR)[PINNED_TAG]
  end

  def pinned_rpc(name)
    rpc = pinned_surface[name]
    raise "#{name} must be registered on #{PINNED_TAG} (rpcs.json)" if rpc.nil?

    rpc
  end

  def required_rpc_names
    @required_rpc_names ||= JSON.parse(File.read(REQUIRED_RPCS_PATH)).fetch("modules").values.flatten.uniq
  end

  def assert_required_rpc(*names, under:)
    doc = JSON.parse(File.read(REQUIRED_RPCS_PATH))
    listed = doc.fetch("modules").fetch(under)
    names.each do |rpc|
      assert_includes listed, rpc, "required_rpcs.json must list #{rpc} under #{under}"
      assert_includes required_rpc_names, rpc
    end
  end
end
