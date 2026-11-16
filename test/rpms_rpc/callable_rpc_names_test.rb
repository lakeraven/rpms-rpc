# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "yaml"
require "rpms_rpc"
require "rpms_rpc/conformance/release_inventory"
require_relative "release_under_test"
require_relative "../../tools/rpc_coverage/rpc_coverage"
require_relative "../../tools/api_coverage/api_coverage"

# Every RPC the gem sends must be CALLABLE on the openrpms release under test (rpms-rpc#394, #724):
# the latest published -ydb release, or OPENRPMS_RELEASE=<tag> (test/rpms_rpc/release_under_test.rb).
#
# "Registered" (registered_rpc_names_test.rb) passed while BMC ADD SECONDARY REFERRAL could not be
# called: its #8994 entry names a label that does not exist (openrpms#653). openrpms now publishes,
# per release, whether each registered RPC is callable (each record's reach in <tag>-rpcs.json, openrpms#713, #732), and
# `rake openrpms:fetch` fetches it into tmp/openrpms/<tag>/. This test reads it through
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
  EXCEPTIONS_PATH = File.join(ROOT, "data/fingerprints/uncallable_exceptions.yml")
  ISSUE = %r{\A[\w.-]+/[\w.-]+#\d+\z}

  # { tag => BuildSurface } of the release under test: one release, the gates' one question.
  def surfaces
    @surfaces ||= begin
      inv = ReleaseUnderTest.inventory(self)
      { inv.tag => inv.surface }
    end
  end

  def exceptions
    @exceptions ||= YAML.safe_load_file(EXCEPTIONS_PATH) || {}
  end

  def api_report
    @api_report ||= ApiCoverage.build(ROOT, surface: surfaces.values.first)
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

  def test_the_release_under_test_has_its_reach_face
    surfaces.each do |tag, surface|
      assert surface.reach?, "#{tag}: its rpcs.json has no reach face"
      assert_equal surface.names.size, surface.rpcs.count(&:reach), "#{tag}: every registered RPC has a reach class"
    end
  end

  # The gate can only judge RPCs it can see: a method whose RPC name static analysis cannot resolve
  # would pass unseen.
  def test_every_public_method_s_rpcs_are_resolved
    unresolved = api_report[:entries].reject { |e| e[:unresolved].empty? }.map { |e| "#{e[:module]}.#{e[:method]}: #{e[:unresolved].join('; ')}" }
    assert_empty unresolved, "the callable gate cannot see these methods' RPCs:\n  #{unresolved.join("\n  ")}"
  end

  def test_every_rpc_a_public_method_sends_is_callable_on_the_release_under_test
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
      warn "\nCALLABLE GATE: #{excepted.size} RPC(s) the gem sends are NOT callable on the release under test, " \
           "excepted as build defects (data/fingerprints/uncallable_exceptions.yml):\n  #{excepted.join("\n  ")}\n"
    end
    assert_empty problems,
                 "#{problems.size} RPC(s) the gem sends are not callable (client-callable or broker-exempt) " \
                 "on the openrpms release under test:\n  #{problems.join("\n  ")}"
  end

  # An exception names a release, an RPC the gem still sends that is still uncallable there in
  # the recorded way, and the issue that tracks the fix.
  def test_every_exception_is_current_and_issue_linked
    problems = exceptions.flat_map do |tag, entries|
      surface = surfaces[tag]
      next [ "#{tag}: not the release under test; remove its exceptions, or re-run with OPENRPMS_RELEASE=#{tag}" ] unless surface

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

  # The gate's question on real rpcs.json records (the committed fixture), one per kind of answer.
  def test_not_callable_names_the_reach_class
    surface = ReleaseUnderTest.fixture.surface

    assert_equal({ "VAFC VOA ADD PATIENT" => "no-context", "BMC ADD SECONDARY REFERRAL" => "no-entry-point",
                   "SC FIND" => "out-of-order", "MAGGECHO" => "no-routine", "ZZZ NOT REGISTERED" => "not registered" },
                 surface.not_callable([ "ORWPT SELECT", "CIANBRPC AUTH", "VAFC VOA ADD PATIENT", "BMC ADD SECONDARY REFERRAL",
                                        "SC FIND", "MAGGECHO", "ZZZ NOT REGISTERED" ]))
    assert_equal "broker-exempt", surface.reach("CIANBRPC AUTH")
    assert_includes surface["ORWPT SELECT"].contexts, "OR CPRS GUI CHART"
    assert_equal [ "cia" ], surface["CIANBRPC AUTH"].exempt_on
  end
end
