# frozen_string_literal: true

require_relative "../mappings"

module RpmsRpc
  # Symbolic API for clinical orders — list-side, scoped either to a user's
  # unsigned queue or to a patient's chart.
  # Underlying RPCs: ORWOR UNSIGN, ORWORR AGET, ORWORR GET4LST, ORWOR VWGET.
  module Order
    extend self

    # Wire view codes for ORWOR VWGET / ORWORR AGET are best-effort
    # placeholders pending wider trace capture; if the codes change, only
    # this table needs updating. Public API uses symbols.
    VIEW_CODES = {
      default:   "1",
      active:    "2",
      expiring:  "3",
      expired:   "4",
      scheduled: "5"
    }.freeze

    STATUS_CODES = {
      all:      "*",
      active:   "A",
      pending:  "P",
      complete: "C",
      expired:  "E"
    }.freeze

    def unsigned_for_user(user_duz)
      return [] if invalid_id?(user_duz)

      Array(DataMapper.orders_unsigned.fetch_many(user_duz.to_s))
    end

    def list(dfn, status: :all, view: :default)
      return [] if invalid_id?(dfn)

      view_code = VIEW_CODES[view]
      raise ArgumentError, "unknown view: #{view.inspect}" if view_code.nil?

      status_code = STATUS_CODES[status]
      raise ArgumentError, "unknown status: #{status.inspect}" if status_code.nil?

      Array(DataMapper.orders_list.fetch_many(dfn.to_s, view_code, status_code))
    end

    private

    def invalid_id?(value)
      value.nil? || value.to_s.strip.empty? || value.to_i <= 0
    end
  end
end
