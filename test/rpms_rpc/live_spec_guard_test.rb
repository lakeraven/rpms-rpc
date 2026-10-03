# frozen_string_literal: true

require "minitest/autorun"
require_relative "../live/live_helper"

# The live-spec harness fails closed (ADR 0009): a spec runs only with a full
# broker env, and a spec that writes runs only against a target declared
# disposable on this machine.
class LiveSpecGuardTest < Minitest::Test
  FULL = { "BROKER_HOST" => "127.0.0.1", "BROKER_PORT" => "19300", "RPMS_ACCESS" => "a",
           "RPMS_VERIFY" => "v", "PERSONA" => "PROV123" }.freeze

  def test_names_every_unset_or_blank_variable
    assert_equal LiveSpec::REQUIRED_ENV, LiveSpec.missing_env({})
    assert_equal %w[RPMS_VERIFY], LiveSpec.missing_env(FULL.merge("RPMS_VERIFY" => " "))
    assert_empty LiveSpec.missing_env(FULL)
  end

  def test_a_write_needs_the_target_declared_disposable
    assert_match(/LIVE_DISPOSABLE/, LiveSpec.write_refusal(FULL))
    assert_match(/LIVE_DISPOSABLE/, LiveSpec.write_refusal(FULL.merge("LIVE_DISPOSABLE" => "yes")))
  end

  def test_a_write_needs_a_loopback_host
    env = FULL.merge("LIVE_DISPOSABLE" => "1", "BROKER_HOST" => "10.0.0.5")
    assert_match(/not loopback/, LiveSpec.write_refusal(env))
  end

  def test_a_disposable_local_target_may_be_written
    assert_nil LiveSpec.write_refusal(FULL.merge("LIVE_DISPOSABLE" => "1"))
  end
end
