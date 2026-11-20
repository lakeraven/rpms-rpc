# frozen_string_literal: true

require "minitest/autorun"
require "rpms_rpc"
require "rpms_rpc/api/phr"
require_relative "../captured_replies"

# The PHR reads: BEHOCCD PHR (portal access, PHR^BEHOCCD), BEHOCIR GETNUM
# (the immunization reconciliation count) and BEHOCCD GETREF (the CCD status
# of a visit's referrals). The replies are test/fixtures/captured_replies/phr.yml,
# captured live as the clinician PROVIDER,TEST and replayed through CiaClient's
# own reply grammar (rpms-rpc#620).
#
# No patient on the build has portal access, a reconciled immunization or a
# CCD referral, so what RPMS answers here is the "none" case for each. The
# access message, the count arithmetic and the referral row layout are not
# proven by a reply RPMS sent; the seeds this file used to carry for them
# were the in-memory fake's, not the server's.
class PhrTest < Minitest::Test
  SLUG = "phr"
  INVALID_IDS = [ nil, "", 0, -5, "abc" ].freeze

  def teardown
    RpmsRpc.reset!
  end

  def replay(flow)
    client = CapturedReplies::ReplayCiaClient.new(CapturedReplies.flow_script(SLUG, flow))
    RpmsRpc.configure { |cfg| cfg.client = client }
    client
  end

  def sent(client) = client.calls.reject { |c| c[:rpc] == :create_context }.map { |c| [ c[:rpc], c[:params] ] }

  # BEHOCCD PHR answers "0" on its first line and no message, for a seed
  # patient, a panel patient and a DFN not on file alike.
  def test_enrollment_status_without_access_carries_the_default_message
    %w[enrollment_seed enrollment_panel enrollment_unknown].zip([ 2, 990_001, 999_999_999 ]).each do |flow, dfn|
      client = replay(flow)

      assert_equal({ enrolled: false, has_access: false, message: "PHR not enrolled" }, RpmsRpc::Phr.enrollment_status(dfn), flow)
      assert_equal CapturedReplies.flow_calls(SLUG, flow), sent(client)
    end
  end

  def test_an_invalid_patient_id_reaches_no_wire
    client = replay("enrollment_seed")

    INVALID_IDS.each do |dfn|
      assert_equal false, RpmsRpc::Phr.enrollment_status(dfn)[:has_access]
      assert_equal false, RpmsRpc::Phr.has_access?(dfn)
      assert_equal({ total: 0, reconciled: 0, pending: 0 }, RpmsRpc::Phr.counts(dfn))
    end
    assert_equal [], RpmsRpc::Phr.referrals_for_visits(INVALID_IDS)
    assert_empty sent(client)
  end

  # BEHOCIR GETNUM answers TOTAL^RECONCILED; with nothing to reconcile, 0^0.
  def test_counts_read_total_and_reconciled
    %w[counts counts_unknown].zip([ 2, 999_999_999 ]).each do |flow, dfn|
      client = replay(flow)

      assert_equal({ total: 0, reconciled: 0, pending: 0 }, RpmsRpc::Phr.counts(dfn), flow)
      assert_equal CapturedReplies.flow_calls(SLUG, flow), sent(client)
    end
  end

  # BEHOCCD GETREF answers nothing for visits with no CCD referral.
  def test_referrals_for_visits_without_a_ccd_referral_are_empty
    client = replay("referrals")

    assert_equal [], RpmsRpc::Phr.referrals_for_visits([ 1, 2 ])
    assert_equal CapturedReplies.flow_calls(SLUG, "referrals"), sent(client)
  end
end
