# frozen_string_literal: true

require "bigdecimal"
require "date"
require "time"

module RpmsRpc
  # Symbolic API for Contract Health Services / Purchased Referred Care budget data.
  module ChsBudget
    extend self

    def fiscal_year_budget(fiscal_year: nil)
      fy = fiscal_year || current_fiscal_year
      row = DataMapper.chs_budget.fetch_one(fy)

      apply_budget_defaults(row, fy)
    end

    def remaining_funds(fiscal_year: nil)
      fy = fiscal_year || current_fiscal_year
      row = DataMapper.chs_remaining_funds.fetch_one(fy)

      apply_funds_defaults(row)
    end

    def quarterly_allocation(quarter: nil, fiscal_year: nil)
      qtr = quarter || current_quarter
      fy = fiscal_year || current_fiscal_year
      row = DataMapper.chs_quarterly_allocation.fetch_one(fy, qtr)

      apply_quarterly_defaults(row, qtr)
    end

    def obligations(status: nil, fiscal_year: nil)
      fy = fiscal_year || current_fiscal_year
      rows = DataMapper.chs_obligation_list.fetch_many(fy, status)
      rows = rows.select { |obligation| obligation[:status] == status } unless blank?(status)

      rows
    end

    def find(ien)
      return nil if invalid_id?(ien)

      DataMapper.chs_obligation_detail.fetch_one(ien.to_s)
    end

    def by_referral(referral_ien)
      return nil if invalid_id?(referral_ien)

      DataMapper.chs_obligation_by_referral.fetch_one(referral_ien.to_s)
    end

    def payments(obligation_id:)
      return [] if blank?(obligation_id)

      DataMapper.chs_payment_list.fetch_many(obligation_id.to_s)
    end

    def outstanding_obligations(fiscal_year: nil)
      obligations(fiscal_year: fiscal_year).select { |o| %w[PENDING PARTIAL].include?(o[:status]) }.map do |obligation|
        paid = payments(obligation_id: obligation[:id]).sum { |payment| decimal(payment[:amount]) }
        amount = decimal(obligation[:amount])

        obligation.merge(amount_paid: paid, amount_due: (amount - paid).round(2))
      end
    end

    def obligation_summary(fiscal_year: nil)
      fy = fiscal_year || current_fiscal_year
      rows = obligations(fiscal_year: fy)
      total_obligated = rows.sum { |obligation| decimal(obligation[:amount]) }
      total_paid = rows.sum do |obligation|
        payments(obligation_id: obligation[:id]).sum { |payment| decimal(payment[:amount]) }
      end

      {
        total_obligated: total_obligated,
        total_paid: total_paid,
        total_outstanding: total_obligated - total_paid,
        by_status: summarize_by_status(rows),
        fiscal_year: fy
      }
    end

    def budget_summary
      budget = fiscal_year_budget
      funds = remaining_funds
      quarters = %w[Q1 Q2 Q3 Q4].to_h { |qtr| [ qtr, quarterly_allocation(quarter: qtr) ] }
      total_budget = decimal(budget[:total_budget])
      remaining = decimal(funds[:remaining])

      {
        fiscal_year: budget[:fiscal_year],
        total_budget: total_budget,
        obligated: decimal(funds[:obligated]),
        expended: decimal(funds[:expended]),
        remaining: remaining,
        percent_remaining: total_budget.positive? ? ((remaining / total_budget) * 100).round(2) : BigDecimal("0"),
        quarters: quarters,
        as_of: Time.now
      }
    end

    def low_funds?(threshold: 0.20)
      budget = fiscal_year_budget
      total = decimal(budget[:total_budget])
      return false unless total.positive?

      (decimal(remaining_funds[:remaining]) / total) < threshold
    end

    def current_fiscal_year
      today = Date.today
      today.month >= 10 ? "FY#{today.year + 1}" : "FY#{today.year}"
    end

    def current_quarter
      case Date.today.month
      when 10, 11, 12 then "Q1"
      when 1, 2, 3 then "Q2"
      when 4, 5, 6 then "Q3"
      when 7, 8, 9 then "Q4"
      end
    end

    private

    def apply_budget_defaults(row, fiscal_year)
      row ||= {}
      row.merge(
        fiscal_year: blank?(row[:fiscal_year]) ? fiscal_year : row[:fiscal_year],
        total_budget: decimal(row[:total_budget])
      )
    end

    def apply_funds_defaults(row)
      row ||= {}
      {
        remaining: decimal(row[:remaining]),
        obligated: decimal(row[:obligated]),
        expended: decimal(row[:expended])
      }
    end

    def apply_quarterly_defaults(row, quarter)
      row ||= {}
      {
        quarter: blank?(row[:quarter]) ? quarter : row[:quarter],
        allocated: decimal(row[:allocated]),
        spent: decimal(row[:spent]),
        remaining: decimal(row[:remaining])
      }
    end

    def summarize_by_status(rows)
      rows.group_by { |obligation| obligation[:status] }.transform_values do |status_rows|
        {
          count: status_rows.size,
          total: status_rows.sum { |obligation| decimal(obligation[:amount]) }
        }
      end
    end

    def decimal(value)
      return BigDecimal("0") if blank?(value)

      BigDecimal(value.to_s)
    rescue ArgumentError
      BigDecimal("0")
    end

    def invalid_id?(value)
      blank?(value) || value.to_i <= 0
    end

    def blank?(value)
      value.nil? || value.to_s.empty?
    end
  end
end
