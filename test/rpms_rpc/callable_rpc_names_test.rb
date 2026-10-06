# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "yaml"
require "rpms_rpc"
require "rpms_rpc/conformance/inventory_lock"
require_relative "../../tools/rpc_coverage/rpc_coverage"
require_relative "../../tools/api_coverage/api_coverage"

# Every RPC the gem sends must be CALLABLE on every pinned rpms-ops build (rpms-rpc#394).
#
# "Registered" (registered_rpc_names_test.rb) passed while BMC ADD SECONDARY REFERRAL could not be
# called: its #8994 entry names a label that does not exist (rpms-ops#653). rpms-ops now publishes,
# per release, whether each registered RPC is callable (<tag>-rpc_reach.txt, rpms-ops#713), and
# `rake conformance:pin` commits it under data/inventories/<tag>/. This test reads it through
# RpmsRpc::Conformance::BuildSurface and holds every RPC the gem sends to it:
#
#   callable  client-callable (a context that is not out of order lists it) or broker-exempt
#             (a broker runs it in any context); anything else fails, named with its reach class
#
# The RPCs considered are the ones each public API method sends (ApiCoverage: static analysis of
# lib/rpms_rpc/api/ through the mappings and helpers it calls), plus every other RPC name lib/
# sends (RpcCoverage.declared_names: the broker clients' sign-on RPCs, mappings no method uses yet).
#
# A failure that comes from a defective build, not from the gem, may be recorded in
# data/fingerprints/uncallable_exceptions.yml with the upstream issue that tracks it. Each one is
# printed on every run, and a stale one fails.
class CallableRpcNamesTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  Lock = RpmsRpc::Conformance::InventoryLock
  LOCK = Lock.load(File.join(ROOT, "data/fingerprints", Lock::DEFAULT_PATH))
  EXCEPTIONS_PATH = File.join(ROOT, "data/fingerprints/uncallable_exceptions.yml")
  ISSUE = %r{\A[\w.-]+/[\w.-]+#\d+\z}

  def surfaces
    @surfaces ||= LOCK.surfaces(inventories_dir: File.join(ROOT, "data/inventories"))
  end

  def exceptions
    @exceptions ||= YAML.safe_load_file(EXCEPTIONS_PATH) || {}
  end

  def api_report
    @api_report ||= ApiCoverage.build(ROOT)
  end

  # { RPC name => [who sends it] }: the public methods first, then the lib/ lines no method reaches.
  def senders
    @senders ||= begin
      out = Hash.new { |h, k| h[k] = [] }
      api_report[:entries].each do |e|
        e[:rpcs].each { |r| out[r[:name]] << "#{e[:module]}.#{e[:method]}" }
      end
      RpcCoverage.declared_names(ROOT).each { |name, sites| out[name].concat(sites) if out[name].empty? }
      out.transform_values(&:uniq)
    end
  end

  def test_every_pinned_build_has_its_reach_face
    refute_empty surfaces, "no rpms-ops build pinned in #{LOCK.path}"
    surfaces.each do |tag, surface|
      assert surface.reach?, "#{tag}: no rpc_reach.txt pinned; re-pin it (rake conformance:pin RELEASE=#{tag})"
      assert_equal surface.names.size, surface.rpcs.count(&:reach), "#{tag}: every registered RPC has a reach class"
    end
  end

  # The gate can only judge RPCs it can see: a method whose RPC name static analysis cannot resolve
  # would pass unseen.
  def test_every_public_method_s_rpcs_are_resolved
    unresolved = api_report[:entries].reject { |e| e[:unresolved].empty? }.map { |e| "#{e[:module]}.#{e[:method]}: #{e[:unresolved].join('; ')}" }
    assert_empty unresolved, "the callable gate cannot see these methods' RPCs:\n  #{unresolved.join("\n  ")}"
  end

  def test_every_rpc_a_public_method_sends_is_callable_on_every_pinned_build
    refute_empty senders
    problems = []
    excepted = []
    surfaces.each do |tag, surface|
      surface.not_callable(senders.keys.sort).each do |name, reach|
        line = "#{name}\t#{reach} on #{tag}\tsent by #{senders[name].join(', ')}"
        exc = exceptions.dig(tag, name)
        if exc && exc["reach"] == reach
          excepted << "#{line}\n      EXCEPTION #{exc['issue']}: #{exc['why'].to_s.strip}"
        else
          problems << line
        end
      end
    end

    unless excepted.empty?
      warn "\nCALLABLE GATE: #{excepted.size} RPC(s) the gem sends are NOT callable on a pinned build, " \
           "excepted as build defects (data/fingerprints/uncallable_exceptions.yml):\n  #{excepted.join("\n  ")}\n"
    end
    assert_empty problems,
                 "#{problems.size} RPC(s) the gem sends are not callable (client-callable or broker-exempt) " \
                 "on a pinned rpms-ops build:\n  #{problems.join("\n  ")}"
  end

  # An exception names a pinned build, an RPC the gem still sends that is still uncallable there in
  # the recorded way, and the issue that tracks the fix.
  def test_every_exception_is_current_and_issue_linked
    problems = exceptions.flat_map do |tag, entries|
      surface = surfaces[tag]
      next [ "#{tag}: not pinned; remove its exceptions" ] unless surface

      entries.filter_map do |name, exc|
        reach = surface.not_callable([ name ])[name]
        if !exc["issue"].to_s.match?(ISSUE) then "#{tag} #{name}: issue #{exc['issue'].inspect} is not owner/repo#N"
        elsif exc["why"].to_s.strip.empty? then "#{tag} #{name}: no why"
        elsif !senders.key?(name) then "#{tag} #{name}: the gem no longer sends it; remove the exception"
        elsif reach.nil? then "#{tag} #{name}: callable now; remove the exception"
        elsif reach != exc["reach"] then "#{tag} #{name}: reach is #{reach}, the exception says #{exc['reach']}"
        end
      end
    end
    assert_empty problems, "stale entries in #{EXCEPTIONS_PATH.delete_prefix("#{ROOT}/")}:\n  #{problems.join("\n  ")}"
  end

  # The gate's question on the shapes a real reach face has (bcer-9.0-20260930-8c88e47-ydb rows).
  def test_not_callable_names_the_reach_class
    Dir.mktmpdir do |dir|
      tag = "bcer-9.0-20260930-8c88e47-ydb"
      rows = {
        "ORWPT SELECT^SELECT^ORWPT^2^R" => "ORWPT SELECT^client-callable^1^1^OR CPRS GUI CHART;CIAV VUECENTRIC^",
        "CIANBRPC AUTH^AUTH^CIANBRPC^2" => "CIANBRPC AUTH^broker-exempt^1^1^^cia",
        "VAFC VOA ADD PATIENT^ADD^VAFCPTAD^2^R^0" => "VAFC VOA ADD PATIENT^no-context^1^1^^",
        "DDR KEY VALIDATOR^KEYVAL^DDR3^2^P" => "DDR KEY VALIDATOR^no-entry-point^1^0^XQAL GUI ALERTS^",
        "SCMC X^X^SCMCX^2" => "SCMC X^out-of-order^1^1^SCMC PCMM GUI WORKSTATION^"
      }
      File.write(File.join(dir, "#{tag}-broker_8994.txt"), "#{rows.keys.join("\n")}\n")
      File.write(File.join(dir, "#{tag}-rpc_reach.txt"), "#{rows.values.join("\n")}\n")
      surface = RpmsRpc::Conformance::BuildSurface.load(dir, tag)

      assert_equal({ "VAFC VOA ADD PATIENT" => "no-context", "DDR KEY VALIDATOR" => "no-entry-point",
                     "SCMC X" => "out-of-order", "ZZZ NOT REGISTERED" => "not registered" },
                   surface.not_callable([ "ORWPT SELECT", "CIANBRPC AUTH", "VAFC VOA ADD PATIENT", "DDR KEY VALIDATOR",
                                          "SCMC X", "ZZZ NOT REGISTERED" ]))
      assert_equal %w[OR\ CPRS\ GUI\ CHART CIAV\ VUECENTRIC], surface["ORWPT SELECT"].contexts
      assert_equal [ "cia" ], surface["CIANBRPC AUTH"].exempt_on
    end
  end
end
