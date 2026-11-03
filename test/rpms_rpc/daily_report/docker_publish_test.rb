# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc/daily_report"

# rpms-rpc#365 panel round 1: attribute a local container only on loopback brokers.
class RpmsRpc::DailyReport::DockerPublishTest < Minitest::Test
  def test_all_interfaces_publish_matches_loopback_broker_hosts
    %w[127.0.0.1 localhost ::1].each do |host|
      assert RpmsRpc::DailyReport.publish_binding_matches_broker?(broker_host: host, publish_host_ip: "0.0.0.0"),
             "expected 0.0.0.0 publish to match #{host}"
      assert RpmsRpc::DailyReport.publish_binding_matches_broker?(broker_host: host, publish_host_ip: "::"),
             "expected :: publish to match #{host}"
    end
  end

  def test_all_interfaces_publish_does_not_match_remote_broker_host
    refute RpmsRpc::DailyReport.publish_binding_matches_broker?(broker_host: "10.0.0.5", publish_host_ip: "0.0.0.0")
    refute RpmsRpc::DailyReport.publish_binding_matches_broker?(broker_host: "broker.example.com", publish_host_ip: "::")
  end

  def test_build_under_test_is_unknown_for_non_loopback_broker_even_when_docker_finds_image
    docker = Class.new do
      def image_publishing_port(_host, _port)
        "ghcr.io/lakeraven/rpms-ydb:bcer-9.0-20269999-remote-ydb"
      end
    end.new

    build = RpmsRpc::DailyReport.build_under_test(
      env: {},
      docker: docker,
      broker_host: "10.0.0.5",
      broker_port: 19_300
    )

    assert_equal "unknown", build
  end
end
