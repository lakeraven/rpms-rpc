# frozen_string_literal: true

require "minitest/autorun"
require "date"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/phr"

class PhrTest < Minitest::Test
  DFN = 8791
  INVALID_IDS = [ nil, "", 0, -5, "abc" ].freeze

  def setup
    RpmsRpc.mock! do |m|
      # BEHOCCD PHR is line-based: line 0 = "1"/"0", line 1 = optional message.
      # seed_text models the multi-line wire shape; fetch_one would only see
      # the first line.
      m.seed_text(:phr_access, DFN.to_s, "1\nPatient portal enabled")
      m.seed_text(:phr_access, "123", "0")

      m.seed(:immunization_count, DFN.to_s, { total: 5, reconciled: 2 })

      m.seed_keyed_collection(:ccd_referral, "9001^9002", [
        {
          referral_ien: 7001, visit_ien: 9001, has_ccd: true,
          ccd_sent_date: Date.new(2026, 5, 10), provider_name: "PROVIDER,TEST",
          facility: "Test Facility"
        },
        {
          referral_ien: 7002, visit_ien: 9002, has_ccd: false,
          ccd_sent_date: nil, provider_name: "PROVIDER,TWO", facility: nil
        }
      ])
    end
  end

  def teardown
    RpmsRpc.reset!
  end

  def test_enrollment_status_returns_access_hash
    status = RpmsRpc::Phr.enrollment_status(DFN)

    assert_equal true, status[:enrolled]
    assert_equal true, status[:has_access]
    assert_equal "Patient portal enabled", status[:message]
  end

  def test_enrollment_status_defaults_blank_message
    status = RpmsRpc::Phr.enrollment_status(123)

    assert_equal false, status[:enrolled]
    assert_equal false, status[:has_access]
    assert_equal "PHR not enrolled", status[:message]
  end

  def test_enrollment_status_rejects_blank_zero_negative_and_nonnumeric_dfn
    INVALID_IDS.each do |dfn|
      assert_equal false, RpmsRpc::Phr.enrollment_status(dfn)[:has_access]
      assert_equal false, RpmsRpc::Phr.has_access?(dfn)
    end
  end

  def test_enrollment_status_returns_disabled_for_unknown_dfn
    status = RpmsRpc::Phr.enrollment_status(999_999)

    assert_equal false, status[:has_access]
    assert_equal "No response", status[:message]
  end

  def test_counts_returns_total_reconciled_and_pending
    counts = RpmsRpc::Phr.counts(DFN)

    assert_equal 5, counts[:total]
    assert_equal 2, counts[:reconciled]
    assert_equal 3, counts[:pending]
  end

  def test_counts_returns_zeroes_for_invalid_or_unknown_dfn
    (INVALID_IDS + [ 999_999 ]).each do |dfn|
      assert_equal({ total: 0, reconciled: 0, pending: 0 }, RpmsRpc::Phr.counts(dfn))
    end
  end

  def test_referrals_for_visits_returns_ccd_status
    referrals = RpmsRpc::Phr.referrals_for_visits([ 9001, 9002 ])

    assert_equal 2, referrals.length
    assert_equal 7001, referrals.first[:referral_ien]
    assert_equal 9001, referrals.first[:visit_ien]
    assert_equal true, referrals.first[:has_ccd]
    assert_equal Date.new(2026, 5, 10), referrals.first[:ccd_sent_date]
  end

  def test_referrals_for_visits_rejects_invalid_ids
    assert_equal [], RpmsRpc::Phr.referrals_for_visits(INVALID_IDS)
  end
end
