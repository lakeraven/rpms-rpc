# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "yaml"
require "rpms_rpc/conformance/reader"

class RpmsRpc::Conformance::ReaderTest < Minitest::Test
  def test_base_reader_fingerprint_is_abstract
    assert_raises(NotImplementedError) do
      RpmsRpc::Conformance::Reader.new.fingerprint
    end
  end

  def test_fixture_reader_loads_a_committed_yaml_into_a_fingerprint
    Dir.mktmpdir do |dir|
      path = File.join(dir, "target.yml")
      File.write(path, YAML.dump(
                         "backend" => "iris_rpms",
                         "lineage" => "rpms",
                         "rpcs" => { "ORWPT SELECT" => { "tag" => "SELECT", "routine" => "ORWPT" } }
                       ))

      fp = RpmsRpc::Conformance::FixtureReader.new(path).fingerprint

      assert_instance_of RpmsRpc::Conformance::Fingerprint, fp
      assert_equal "iris_rpms", fp.backend
      assert_equal Set["ORWPT SELECT"], fp.rpc_names
    end
  end

  def test_broker_reader_is_a_documented_stub
    error = assert_raises(NotImplementedError) do
      RpmsRpc::Conformance::BrokerReader.new(client: :some_client).fingerprint
    end
    assert_match(/follow-up: live capture/, error.message)
  end

  def test_iris_sql_reader_is_a_documented_stub
    error = assert_raises(NotImplementedError) do
      RpmsRpc::Conformance::IrisSqlReader.new(connection: :some_connection).fingerprint
    end
    assert_match(/follow-up: live capture/, error.message)
  end
end
