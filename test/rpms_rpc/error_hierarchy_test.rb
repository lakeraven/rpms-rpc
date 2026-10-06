# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/cia_client"
require "rpms_rpc/xwb_client"
require "rpms_rpc/bmx_client"
require "rpms_rpc/session_pool"
require "rpms_rpc/wire_capture"
require "rpms_rpc/conformance"
require "rpms_rpc/conformance/inventory_lock"

# Every exception the gem raises descends from RpmsRpc::Error (ADR 0010,
# assertion 4; rpms-rpc#357), so a host rescues RPMS failures in one place
# and tells them apart by type. The class names and the relationships between
# them are unchanged, so a host's existing rescues keep working.
class ErrorHierarchyTest < Minitest::Test
  # The classes #357 names, plus the broker subclasses #363 added.
  NAMED = [
    RpmsRpc::NotConfiguredError,
    RpmsRpc::Client::AuthenticationError,
    RpmsRpc::Client::CredentialError,
    RpmsRpc::Client::ConnectionError,
    RpmsRpc::Client::TimeoutError,
    RpmsRpc::Client::RpcTimeoutError,
    RpmsRpc::Client::RpcError,
    RpmsRpc::Client::RpcNotAvailableError,
    RpmsRpc::Client::RpcRefusedError,
    RpmsRpc::XmlResponseParser::RpcError,
    RpmsRpc::XmlResponseParser::ParseError,
    RpmsRpc::ParameterEncoder::ParameterTooLongError,
    RpmsRpc::XwbClient::SpackTooLongError,
    RpmsRpc::SessionPool::PoolExhaustedError,
    RpmsRpc::SessionPool::SessionOccupiedError
  ].freeze

  def test_error_is_a_standard_error
    assert_operator RpmsRpc::Error, :<, StandardError
  end

  NAMED.each do |klass|
    define_method("test_rescue_rpms_rpc_error_catches_#{klass.name.delete_prefix("RpmsRpc::").tr(":", "_").downcase}") do
      caught = begin
        raise klass, "provoked"
      rescue RpmsRpc::Error => e
        e
      end
      assert_instance_of klass, caught
    end
  end

  # AC 3, checked on the loaded classes rather than the source text: no
  # exception class defined in the RpmsRpc namespace sits outside the hierarchy.
  def test_every_exception_class_in_the_namespace_descends_from_error
    outside = ObjectSpace.each_object(Class).select do |c|
      c < Exception && c.name.to_s.start_with?("RpmsRpc::") && !(c <= RpmsRpc::Error)
    end
    assert_empty outside.map(&:name).sort, "exception classes outside RpmsRpc::Error"
  end

  # AC 4: the relationships a host's rescues may already rely on.
  def test_existing_relationships_are_kept
    assert_operator RpmsRpc::Client::CredentialError, :<, RpmsRpc::Client::AuthenticationError
    assert_operator RpmsRpc::Client::TimeoutError, :<, RpmsRpc::Client::ConnectionError
    assert_operator RpmsRpc::Client::RpcTimeoutError, :<, RpmsRpc::Client::TimeoutError
    assert_operator RpmsRpc::Client::RpcNotAvailableError, :<, RpmsRpc::Client::RpcError
    assert_operator RpmsRpc::Client::RpcRefusedError, :<, RpmsRpc::Client::RpcError
  end

  # A host that rescues StandardError, or a specific class, is unaffected.
  def test_a_rescue_of_a_specific_class_still_works
    assert_raises(RpmsRpc::NotConfiguredError) { RpmsRpc.reset!; RpmsRpc.client }
  end

  # The distinct types a host tells apart (the HTTP-like shape from the issue
  # thread) stay distinct: none is a subclass of another.
  def test_the_failure_kinds_are_distinct
    kinds = [
      RpmsRpc::Client::AuthenticationError,
      RpmsRpc::Client::ConnectionError,
      RpmsRpc::Client::RpcError,
      RpmsRpc::NotConfiguredError,
      RpmsRpc::XmlResponseParser::ParseError
    ]
    kinds.combination(2).each do |a, b|
      refute_operator a, :<=, b, "#{a} should not be a #{b}"
      refute_operator b, :<=, a, "#{b} should not be a #{a}"
    end
  end
end
