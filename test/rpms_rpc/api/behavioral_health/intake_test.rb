# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/behavioral_health/intake"
require_relative "../../captured_replies"

# RpmsRpc::BehavioralHealth::Intake on the AMHG replies a fresh rpms-ydb
# container sent (test/fixtures/captured_replies/amhg-reference.yml), replayed
# through CiaClient's GLOBAL ARRAY read, per ADR 0009: the parameter each read
# sends and the empty answer. A fresh container has no BH intake, so a filled
# row is not pinned here; the round trip is
# test/live/behavioral_health_reference_live_test.rb (rpms-rpc#622).
class BehavioralHealthIntakeTest < Minitest::Test
  I = RpmsRpc::BehavioralHealth::Intake
  SLUG = "amhg-reference"

  def teardown
    RpmsRpc.reset!
  end

  def capture(name) = CapturedReplies.file(SLUG).fetch("captures").find { |c| c["name"] == name }

  def replay(name)
    client = CapturedReplies::ReplayCiaClient.new(capture(name)["rpc"] => [ CapturedReplies.raw(SLUG, name) ])
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def sent(client) = client.calls.reject { |c| c[:rpc] == :create_context }

  # INTAKEL^AMHGDA's third piece is the patient, not a provider (AMHGDA.m:148).
  def test_intakes_with_none_on_file_is_empty_and_sends_from_to_dfn
    client = replay("intakes_none")

    assert_empty I.intakes("4", from: "3000101", to: "3271231"), "the typed header is not an intake"
    assert_equal [ { rpc: "AMHG GET INTAKE", params: capture("intakes_none")["inputs"] } ], sent(client)
  end

  # INT^AMHGDINT takes patient|program|from|to, not an intake IEN.
  def test_intake_documents_with_none_on_file_is_empty_and_sends_dfn_program_dates
    client = replay("intake_documents_none")

    assert_empty I.intake_documents("4", program: "M", from: "3000101", to: "3271231")
    assert_equal [ { rpc: "AMHG GET INTAKE DOCUMENTS", params: capture("intake_documents_none")["inputs"] } ], sent(client)
  end
end
