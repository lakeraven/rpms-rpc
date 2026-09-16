# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc/mock_client"

class RpmsRpc::ConfigurationTest < Minitest::Test
  def teardown
    RpmsRpc.reset!
  end

  # -- configure + client ----------------------------------------------------

  def test_configure_sets_client
    mock = RpmsRpc::MockClient.new
    RpmsRpc.configure { |c| c.client = mock }

    assert_equal mock, RpmsRpc.client
  end

  def test_client_raises_when_not_configured
    assert_raises(RpmsRpc::NotConfiguredError) { RpmsRpc.client }
  end

  def test_reset_clears_client
    RpmsRpc.configure { |c| c.client = RpmsRpc::MockClient.new }
    RpmsRpc.reset!
    assert_raises(RpmsRpc::NotConfiguredError) { RpmsRpc.client }
  end

  # -- module-level synchronize_wire must FAIL CLOSED ------------------------

  # A client that forwards call_rpc but does not define synchronize_wire
  # (a wrapper / delegator) used to make RpmsRpc.synchronize_wire yield
  # UNLOCKED. That is weaker than the pre-0.3.0 world, where the absence of
  # the method was VISIBLE to callers (respond_to? false → their own mutex
  # fallback). Post-0.3.0 the module method exists, so #486's respond_to?
  # guard is vacuously true and its fallback is dead code — a non-conforming
  # client would then unlock silently. The module path must serialize
  # regardless, with a process-wide fallback lock.
  class WireLocklessClient
    attr_reader :log

    def initialize
      @log = []
      @mutex = Mutex.new
    end

    # NOT synchronize_wire — this stands in for a wrapper that only forwards
    # the RPC surface.
    def call_rpc(_name, *_params)
      @mutex.synchronize { @log << :enter }
      sleep 0.02
      @mutex.synchronize { @log << :exit }
    end
  end

  def test_module_synchronize_wire_fails_closed_for_a_lockless_client
    client = WireLocklessClient.new
    refute client.respond_to?(:synchronize_wire), "precondition: client has no wire lock of its own"
    RpmsRpc.configure { |c| c.client = client }

    threads = Array.new(4) do
      Thread.new { RpmsRpc.synchronize_wire { client.call_rpc("X") } }
    end
    threads.each(&:join)

    # Serialized: every enter is immediately followed by its own exit.
    client.log.each_slice(2) do |enter, exit|
      assert_equal [ :enter, :exit ], [ enter, exit ],
        "RpmsRpc.synchronize_wire yielded UNLOCKED for a client without its own " \
        "wire lock: #{client.log.inspect}"
    end
  end

  # -- mock! convenience -----------------------------------------------------

  def test_mock_returns_a_mock_client
    mock = RpmsRpc.mock!
    assert_kind_of RpmsRpc::MockClient, mock
    assert_equal mock, RpmsRpc.client
  end

  def test_mock_accepts_block_for_seeding
    RpmsRpc.mock! do |m|
      m.seed(:patient_select, "1", { name: "DOE,JOHN", sex: "M" })
    end

    result = RpmsRpc::DataMapper.patient_select.fetch_one("1")
    assert_equal "DOE,JOHN", result[:name]
  end

  # -- fetch without explicit client -----------------------------------------

  def test_fetch_one_uses_configured_client
    RpmsRpc.mock! do |m|
      m.seed(:patient_select, "1", { name: "DOE,JOHN", sex: "M", dob: Date.new(1980, 1, 15), ssn: "111", age: 45 })
    end

    result = RpmsRpc::DataMapper.patient_select.fetch_one("1")
    assert_equal "DOE,JOHN", result[:name]
    assert_equal "M", result[:sex]
  end

  def test_fetch_many_uses_configured_client
    RpmsRpc.mock! do |m|
      m.seed_collection(:patient_list, [
        { dfn: 1, name: "DOE,JOHN" },
        { dfn: 2, name: "SMITH,JANE" }
      ])
    end

    results = RpmsRpc::DataMapper.patient_list.fetch_many("", "1")
    assert_equal 2, results.size
  end

  def test_fetch_scalar_uses_configured_client
    RpmsRpc.mock! do |m|
      m.seed_scalar(:patient_sensitive, "1", true)
    end

    assert_equal true, RpmsRpc::DataMapper.patient_sensitive.fetch_scalar("1")
  end

  def test_fetch_one_raises_when_not_configured
    assert_raises(RpmsRpc::NotConfiguredError) do
      RpmsRpc::DataMapper.patient_select.fetch_one("1")
    end
  end

  # -- search filtering on mock ----------------------------------------------

  def test_mock_seed_collection_with_filter
    RpmsRpc.mock! do |m|
      m.seed_collection(:patient_list, [
        { dfn: 1, name: "DOE,JOHN" },
        { dfn: 2, name: "SMITH,JANE" },
        { dfn: 3, name: "DOE,JANE" }
      ], filter_field: :name)
    end

    # Search for "DOE" — should filter by name prefix
    results = RpmsRpc::DataMapper.patient_list.fetch_many("DOE", "1")
    assert_equal 2, results.size
    assert results.all? { |r| r[:name].upcase.start_with?("DOE") }

    # Search for "SMITH"
    results = RpmsRpc::DataMapper.patient_list.fetch_many("SMITH", "1")
    assert_equal 1, results.size

    # Search for nonexistent
    results = RpmsRpc::DataMapper.patient_list.fetch_many("ZZZZZ", "1")
    assert_equal [], results
  end
end
