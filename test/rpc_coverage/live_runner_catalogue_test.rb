# frozen_string_literal: true

require "minitest/autorun"
require "prism"

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
# catalogue's `RpmsRpc::Module.method` call sites and checks each one offline: the method exists, and takes the
# number of positional arguments the catalogue passes (Vital.template was called with one of its two, #795).
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

  def test_every_catalogue_call_passes_as_many_positional_arguments_as_the_method_takes
    wrong = calls.filter_map do |mod, meth, given, line|
      next unless RpmsRpc.const_defined?(mod) && RpmsRpc.const_get(mod).respond_to?(meth)

      params = RpmsRpc.const_get(mod).method(meth).parameters
      required = params.count { |kind, _| kind == :req }
      optional = params.count { |kind, _| kind == :opt }
      next if given >= required && (params.any? { |kind, _| kind == :rest } || given <= required + optional)

      "RpmsRpc::#{mod}.#{meth} at live_runner.rb:#{line} passes #{given}, takes #{required}#{"..#{required + optional}" if optional.positive?}"
    end
    refute_empty calls
    assert_empty wrong, "the live catalogue calls methods with the wrong number of arguments"
  end

  # [module, method, positional argument count, line] for every RpmsRpc::Module.method(...) call in the runner.
  def calls
    @calls ||= begin
      found = []
      walk = lambda do |node|
        if node.is_a?(Prism::CallNode) && (mod = rpms_module(node.receiver))
          args = node.arguments&.arguments || []
          found << [ mod, node.name.to_s, args.count { |a| !a.is_a?(Prism::KeywordHashNode) }, node.location.start_line ]
        end
        node.compact_child_nodes.each { |c| walk.call(c) }
      end
      walk.call(Prism.parse_file(RUNNER).value)
      found
    end
  end

  def rpms_module(receiver)
    return unless receiver.is_a?(Prism::ConstantPathNode)

    receiver.full_name.delete_prefix("RpmsRpc::") if receiver.full_name.start_with?("RpmsRpc::")
  end
end
