# frozen_string_literal: true

require "json"
require "rpms_rpc/conformance/release_inventory"
require_relative "release_under_test"

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

# Shared helpers for rpms-rpc#420 stock-RPC wrapper tests. pinned_rpc reads the openrpms release under
# test (the latest published -ydb release, rpms-rpc#724): a wrapped RPC must be registered there, in
# the context the wrapper binds.
module StockRpcsTestHelper
  ROOT = File.expand_path("../..", __dir__)
  REQUIRED_RPCS_PATH = File.join(ROOT, "lib/rpms_rpc/required_rpcs.json")

  module_function

  def pinned_surface = ReleaseUnderTest.surface(self)

  def pinned_rpc(name)
    rpc = pinned_surface[name]
    flunk "#{name} must be registered on #{pinned_surface.tag} (rpcs.json)" if rpc.nil?

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
