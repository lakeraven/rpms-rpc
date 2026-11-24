# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc"
require "rpms_rpc/api/phr"
require_relative "../captured_replies"

# The PHR reads: BEHOCCD PHR (whether the patient uses their PHR, PHR^BEHOCCD),
# BEHOCIR GETNUM (the immunization reconciliation count) and BEHOCCD GETREF
# (the referrals on a visit). The replies are test/fixtures/captured_replies/phr.yml,
# captured live as the provider test role, PROFILE,MD, after setup filed PHR
# answers for DFN 2 (YES) and DFN 4 (YES, then NO) and a V REFERRAL on visit 2,
# and replayed through CiaClient's own reply grammar (rpms-rpc#620, #221).
#
# No patient on the build has a reconciled immunization, so the count is
# the "none" case; its arithmetic is not proven by a reply RPMS sent.
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

  # BEHOCCD PHR answers "0" for a patient with no answer on file and for a
  # DFN not on file alike.
  def test_enrollment_status_with_no_answer_on_file_is_not_enrolled
    %w[enrollment_panel enrollment_unknown].zip([ 990_001, 999_999_999 ]).each do |flow, dfn|
      client = replay(flow)

      assert_equal({ enrolled: false, has_access: false, answered_on: nil, message: "PHR not enrolled" },
                   RpmsRpc::Phr.enrollment_status(dfn), flow)
      assert_equal CapturedReplies.flow_calls(SLUG, flow), sent(client)
    end
  end

  # A patient who said YES: "1^MM/DD/YYYY", the latest answer and its date.
  # The whole line was compared with "1", so this read as not enrolled.
  def test_enrollment_status_of_a_patient_who_said_yes_is_enrolled_with_the_date
    replay("enrollment_yes")

    status = RpmsRpc::Phr.enrollment_status(2)

    assert_equal true, status[:enrolled]
    assert_equal true, status[:has_access]
    assert_equal answered_on("enrollment_yes"), status[:answered_on]
    assert_equal "PHR access enabled", status[:message]
  end

  # DFN 4 said YES, then NO: only the latest answer counts.
  def test_enrollment_status_reads_the_latest_answer
    replay("enrollment_no")

    status = RpmsRpc::Phr.enrollment_status(4)

    assert_equal false, status[:has_access]
    assert_equal answered_on("enrollment_no"), status[:answered_on]
  end

  def test_an_invalid_patient_id_reaches_no_wire
    client = replay("enrollment_panel")

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

  # BEHOCCD GETREF reads the visits as a list parameter and answers one row
  # per V REFERRAL: the visit, the RCIS referral, the patient, then the
  # referral's purpose, status and number and its vendor's fields.
  def test_referrals_for_visits_sends_a_list_and_reads_each_v_referral
    client = replay("referrals")

    rows = RpmsRpc::Phr.referrals_for_visits([ 1, 2 ])

    assert_equal [ [ "BEHOCCD GETREF", [ %w[1 2] ] ] ], sent(client)
    assert_equal [ { visit_ien: 2, referral_ien: 1, patient_ien: 4, purpose: nil, status: "ACTIVE",
                     referral_number: "9000000000221", vendor_fax: nil, vendor_direct_participant: nil,
                     vendor_direct_email: nil, vendor_name: nil } ], rows
  end

  def test_referrals_for_a_visit_with_none_are_empty
    client = replay("referrals_none")

    assert_equal [], RpmsRpc::Phr.referrals_for_visits([ 1 ])
    assert_equal CapturedReplies.flow_calls(SLUG, "referrals_none"), sent(client)
  end

  private

  # The date in a recorded "ACCESS^MM/DD/YYYY" reply.
  def answered_on(flow)
    Date.strptime(CapturedReplies.flow(SLUG, flow).first.fetch("raw_return").split("^").last, "%m/%d/%Y")
  end
end
