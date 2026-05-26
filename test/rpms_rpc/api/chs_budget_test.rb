# frozen_string_literal: true

require "bigdecimal"
require "date"
require "minitest/autorun"
require "rpms_rpc/version"
require "rpms_rpc/mock_client"
require "rpms_rpc/api/chs_budget"

class ChsBudgetTest < Minitest::Test
  FY = RpmsRpc::ChsBudget.current_fiscal_year
  # Derive FY date bounds from the dynamic FY string so the test stays
  # green across fiscal-year rollovers. FY runs Oct 1 (prior calendar year)
  # through Sep 30 (FY year).
  FY_YEAR  = FY.delete_prefix("FY").to_i
  FY_START = Date.new(FY_YEAR - 1, 10, 1)
  FY_END   = Date.new(FY_YEAR, 9, 30)

  def setup
    RpmsRpc.mock! do |m|
      m.seed(:chs_budget, FY, {
        fiscal_year: FY,
        total_budget: "1000000.00",
        start_date: FY_START,
        end_date: FY_END
      })

      m.seed(:chs_remaining_funds, FY, {
        remaining: "750000.00",
        obligated: "200000.00",
        expended: "50000.00"
      })

      %w[Q1 Q2 Q3 Q4].each_with_index do |quarter, index|
        m.seed(:chs_quarterly_allocation, "#{FY}:#{quarter}", {
          quarter: quarter,
          allocated: "250000.00",
          spent: (50_000 + (index * 10_000)).to_s,
          remaining: (200_000 - (index * 10_000)).to_s
        })
      end

      # Also seed the keys used by the production call shape: fiscal year first.
      m.seed(:chs_quarterly_allocation, FY, {
        quarter: "Q1",
        allocated: "250000.00",
        spent: "50000.00",
        remaining: "200000.00"
      })

      m.seed_keyed_collection(:chs_obligation_list, FY, [
        {
          id: "101",
          referral_ien: 501,
          patient_dfn: 8791,
          amount: "15000.00",
          status: "PENDING",
          service_type: "Specialty Care",
          created_date: Date.new(2026, 1, 15)
        },
        {
          id: "102",
          referral_ien: 502,
          patient_dfn: 8792,
          amount: "25000.00",
          status: "PAID",
          service_type: "Surgery",
          created_date: Date.new(2026, 1, 20)
        }
      ])

      m.seed(:chs_obligation_detail, "101", {
        id: "101",
        referral_ien: 501,
        patient_dfn: 8791,
        amount: "15000.00",
        amount_paid: "5000.00",
        status: "PARTIAL",
        service_type: "Specialty Care",
        vendor_id: "701",
        created_date: Date.new(2026, 1, 15)
      })

      m.seed(:chs_obligation_by_referral, "501", {
        id: "101",
        referral_ien: 501,
        patient_dfn: 8791,
        amount: "15000.00",
        amount_paid: "5000.00",
        status: "PARTIAL",
        service_type: "Specialty Care",
        vendor_id: "701",
        created_date: Date.new(2026, 1, 15)
      })

      m.seed_keyed_collection(:chs_payment_list, "101", [
        {
          id: "301",
          obligation_id: "101",
          amount: "5000.00",
          payment_date: Date.new(2026, 2, 1),
          check_number: "CHK-12345",
          vendor_id: "701",
          created_date: Date.new(2026, 2, 1)
        },
        {
          id: "302",
          obligation_id: "101",
          amount: "2500.00",
          payment_date: Date.new(2026, 2, 15),
          check_number: "CHK-12346",
          vendor_id: "701",
          created_date: Date.new(2026, 2, 15)
        }
      ])

      m.seed(:chs_budget, "FY_BLANK", {
        fiscal_year: nil,
        total_budget: nil,
        start_date: nil,
        end_date: nil
      })
      m.seed(:chs_remaining_funds, "FY_BLANK", {
        remaining: nil,
        obligated: nil,
        expended: nil
      })
      m.seed(:chs_quarterly_allocation, "FY_BLANK", {
        quarter: nil,
        allocated: nil,
        spent: nil,
        remaining: nil
      })
    end
  end

  def teardown
    RpmsRpc.reset!
  end

  def test_fiscal_year_budget_returns_budget_allocation
    budget = RpmsRpc::ChsBudget.fiscal_year_budget(fiscal_year: FY)

    assert_equal FY, budget[:fiscal_year]
    assert_equal BigDecimal("1000000.00"), budget[:total_budget]
    assert_equal FY_START, budget[:start_date]
    assert_equal FY_END, budget[:end_date]
  end

  def test_fiscal_year_budget_defaults_unknown_or_blank_response
    missing = RpmsRpc::ChsBudget.fiscal_year_budget(fiscal_year: "FY2099")
    blank = RpmsRpc::ChsBudget.fiscal_year_budget(fiscal_year: "FY_BLANK")

    assert_equal "FY2099", missing[:fiscal_year]
    assert_equal BigDecimal("0"), missing[:total_budget]
    assert_equal "FY_BLANK", blank[:fiscal_year]
    assert_equal BigDecimal("0"), blank[:total_budget]
  end

  def test_remaining_funds_returns_fiscal_year_totals
    funds = RpmsRpc::ChsBudget.remaining_funds(fiscal_year: FY)

    assert_equal BigDecimal("750000.00"), funds[:remaining]
    assert_equal BigDecimal("200000.00"), funds[:obligated]
    assert_equal BigDecimal("50000.00"), funds[:expended]
  end

  def test_remaining_funds_defaults_blank_fields_to_zero
    funds = RpmsRpc::ChsBudget.remaining_funds(fiscal_year: "FY_BLANK")

    assert_equal BigDecimal("0"), funds[:remaining]
    assert_equal BigDecimal("0"), funds[:obligated]
    assert_equal BigDecimal("0"), funds[:expended]
  end

  def test_quarterly_allocation_sends_fiscal_year_then_quarter
    RpmsRpc::ChsBudget.quarterly_allocation(quarter: "Q1", fiscal_year: FY)

    call = RpmsRpc.client.received_calls.find { |c| c[:rpc] == "BMCRPC GTQTRALLOC" }
    refute_nil call
    assert_equal [ FY, "Q1" ], call[:params]
  end

  def test_quarterly_allocation_defaults_blank_fields
    allocation = RpmsRpc::ChsBudget.quarterly_allocation(quarter: "Q3", fiscal_year: "FY_BLANK")

    assert_equal "Q3", allocation[:quarter]
    assert_equal BigDecimal("0"), allocation[:allocated]
    assert_equal BigDecimal("0"), allocation[:spent]
    assert_equal BigDecimal("0"), allocation[:remaining]
  end

  def test_obligations_returns_multi_line_obligations
    obligations = RpmsRpc::ChsBudget.obligations(fiscal_year: FY)

    assert_equal 2, obligations.length
    pending = obligations.find { |o| o[:id] == "101" }
    assert_equal "501", pending[:referral_ien]
    assert_equal "8791", pending[:patient_dfn]
    assert_equal "15000.00", pending[:amount]
    assert_equal Date.new(2026, 1, 15), pending[:created_date]
  end

  def test_obligations_filters_by_status
    obligations = RpmsRpc::ChsBudget.obligations(status: "PENDING", fiscal_year: FY)

    assert_equal [ "101" ], obligations.map { |o| o[:id] }
  end

  def test_find_returns_single_obligation
    obligation = RpmsRpc::ChsBudget.find(101)

    refute_nil obligation
    assert_equal "101", obligation[:id]
    assert_equal "PARTIAL", obligation[:status]
    assert_equal "5000.00", obligation[:amount_paid]
    assert_equal "701", obligation[:vendor_id]
  end

  def test_find_rejects_blank_zero_negative_and_non_numeric_ids
    assert_nil RpmsRpc::ChsBudget.find(nil)
    assert_nil RpmsRpc::ChsBudget.find("")
    assert_nil RpmsRpc::ChsBudget.find(0)
    assert_nil RpmsRpc::ChsBudget.find(-1)
    assert_nil RpmsRpc::ChsBudget.find("NONEXISTENT")
  end

  def test_find_returns_nil_for_unknown_id
    assert_nil RpmsRpc::ChsBudget.find(999_999)
  end

  def test_by_referral_returns_single_obligation
    obligation = RpmsRpc::ChsBudget.by_referral(501)

    refute_nil obligation
    assert_equal "101", obligation[:id]
    assert_equal "501", obligation[:referral_ien]
  end

  def test_by_referral_accepts_non_numeric_referral_id
    RpmsRpc.client.seed(:chs_obligation_by_referral, "REF-001", {
      id: "OBL-099",
      referral_ien: "REF-001",
      patient_dfn: "8791",
      amount: "1200.00",
      status: "PENDING"
    })

    obligation = RpmsRpc::ChsBudget.by_referral("REF-001")
    refute_nil obligation, "non-numeric referral IDs must reach the RPC"
    assert_equal "REF-001", obligation[:referral_ien]
    assert_equal "OBL-099", obligation[:id]
  end

  def test_payments_returns_multi_line_payments
    payments = RpmsRpc::ChsBudget.payments(obligation_id: 101)

    assert_equal 2, payments.length
    assert_equal "301", payments.first[:id]
    assert_equal "CHK-12345", payments.first[:check_number]
    assert_equal Date.new(2026, 2, 1), payments.first[:payment_date]
  end

  def test_payments_returns_empty_for_blank_or_unknown_obligation
    assert_equal [], RpmsRpc::ChsBudget.payments(obligation_id: nil)
    assert_equal [], RpmsRpc::ChsBudget.payments(obligation_id: "")
    assert_equal [], RpmsRpc::ChsBudget.payments(obligation_id: 999_999)
  end

  def test_outstanding_obligations_calculates_amount_due
    outstanding = RpmsRpc::ChsBudget.outstanding_obligations(fiscal_year: FY)

    assert_equal 1, outstanding.length
    assert_equal "101", outstanding.first[:id]
    assert_equal BigDecimal("7500.00"), outstanding.first[:amount_paid]
    assert_equal BigDecimal("7500.00"), outstanding.first[:amount_due]
  end

  def test_obligation_summary_returns_totals_by_status
    summary = RpmsRpc::ChsBudget.obligation_summary(fiscal_year: FY)

    assert_equal BigDecimal("40000.00"), summary[:total_obligated]
    assert_equal BigDecimal("7500.00"), summary[:total_paid]
    assert_equal BigDecimal("32500.00"), summary[:total_outstanding]
    assert_equal 1, summary[:by_status]["PENDING"][:count]
    assert_equal BigDecimal("25000.00"), summary[:by_status]["PAID"][:total]
  end

  def test_budget_summary_returns_comprehensive_budget_overview
    summary = RpmsRpc::ChsBudget.budget_summary

    assert_equal RpmsRpc::ChsBudget.current_fiscal_year, summary[:fiscal_year]
    assert_equal BigDecimal("1000000.00"), summary[:total_budget]
    assert_equal BigDecimal("75.0"), summary[:percent_remaining]
    assert_equal %w[Q1 Q2 Q3 Q4], summary[:quarters].keys
    assert_kind_of Time, summary[:as_of]
  end

  def test_low_funds_detects_threshold
    assert_equal false, RpmsRpc::ChsBudget.low_funds?(threshold: 0.20)
    assert_equal true, RpmsRpc::ChsBudget.low_funds?(threshold: 0.80)
  end
end
