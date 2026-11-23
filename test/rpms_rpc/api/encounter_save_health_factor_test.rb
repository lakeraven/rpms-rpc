# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/encounter"
require_relative "../captured_replies"

# Encounter.save reads each health factor from HEALTH FACTORS (#9999999.64)
# before BEHOENPC SAVE, and refuses one the build has no entry for: the build
# would file HF+^<ien> as a V HEALTH FACTOR whose .01 points at nothing,
# into the patient's record (rpms-rpc#928). The replies are the build's
# (test/fixtures/captured_replies/health-factor-entry.yml), read through the
# real CiaClient; the client fails the test on any RPC it has no reply for,
# so a refusal that reached the snapshot or the save would fail here.
class EncounterSaveHealthFactorTest < Minitest::Test
  SLUG = "health-factor-entry"

  def teardown
    RpmsRpc.reset!
  end

  def replay(*captures)
    client = CapturedReplies::ReplayCiaClient.new("DDR GETS ENTRY DATA" => captures.map { |c| CapturedReplies.raw(SLUG, c) })
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def save(health_factors)
    RpmsRpc::Encounter.save(990_053, location_ien: 6, datetime: "3261122.1030", service_category: "A",
                                     provider_duz: 206, health_factors: health_factors)
  end

  def test_a_health_factor_not_on_file_is_refused_before_anything_is_filed
    client = replay("not_on_file")

    result = save([ { ien: 999_999 } ])

    refute result[:success]
    assert_equal :invalid, result[:error]
    refute result[:may_have_filed]
    assert_equal [ { kind: :health_factor, factor_ien: 999_999, reason: :unknown_health_factor } ], result[:not_filed]
    assert_equal [ "DDR GETS ENTRY DATA" ], client.rpcs_called.reject { |r| r == :create_context },
                 "only the HEALTH FACTORS read is sent: no snapshot, no BEHOENPC SAVE"
    assert_equal [ { "FILE" => "9999999.64", "IENS" => "999999,", "FIELDS" => ".01", "FLAGS" => "I" } ],
                 client.calls.find { |c| c[:rpc] == "DDR GETS ENTRY DATA" }[:params]
  end

  def test_each_unknown_factor_is_named_beside_a_known_one
    client = replay("on_file", "not_on_file")

    result = save([ { ien: 25 }, { ien: 999_999 } ])

    assert_equal :invalid, result[:error]
    assert_equal [ { kind: :health_factor, factor_ien: 999_999, reason: :unknown_health_factor } ], result[:not_filed]
    refute_includes client.rpcs_called, "BEHOENPC SAVE"
  end
end
