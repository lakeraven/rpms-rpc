# frozen_string_literal: true

require "minitest/autorun"

LIB = File.expand_path("../../lib", __dir__) unless defined?(LIB)
$LOAD_PATH.unshift(LIB)
require "rpms_rpc/cia_client"
require "rpms_rpc/mappings"
Dir[File.join(LIB, "rpms_rpc/api/*.rb")].each { |f| require f }

# rake rpc:live: every API method the live catalogue calls must exist.
#
# The catalogue in tools/rpc_coverage/live_runner.rb is only exercised against a live
# broker, so a case naming a retired method (Problem.filter, retired with #188) went
# unnoticed until a live run reported it as raised-before-wire. This reads the
# catalogue's `RpmsRpc::Module.method` call sites and checks each one offline.
class LiveRunnerCatalogueTest < Minitest::Test
  RUNNER = File.expand_path("../../tools/rpc_coverage/live_runner.rb", __dir__)
  CALL = /RpmsRpc::([A-Z][A-Za-z]*(?:::[A-Z][A-Za-z]*)*)\.([a-z_][a-z0-9_]*[?!]?)/

  def call_sites
    File.read(RUNNER).scan(CALL).uniq
  end

  def test_the_catalogue_names_api_methods
    refute_empty call_sites, "no RpmsRpc::Module.method call sites found in #{RUNNER}"
  end

  def test_every_catalogue_call_names_an_existing_method
    missing = call_sites.reject do |mod, meth|
      RpmsRpc.const_defined?(mod) && RpmsRpc.const_get(mod).respond_to?(meth)
    end
    assert_empty missing.map { |mod, meth| "RpmsRpc::#{mod}.#{meth}" },
                 "the live catalogue calls methods that do not exist"
  end
end
