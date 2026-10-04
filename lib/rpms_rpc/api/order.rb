# frozen_string_literal: true

require_relative "../mappings"

module RpmsRpc
  # Symbolic API for clinical orders — list-side, scoped either to a user's
  # unsigned queue or to a patient's chart, plus per-order result reads
  # and order-sheet catalog reads for the order-review surface.
  # Underlying RPCs: ORWOR UNSIGN, ORWORR AGET, ORWOR RESULT,
  # ORWOR RESULT HISTORY, ORWOR ACTION TEXT, ORWOR EXPIRED, ORWOR SHEETS,
  # ORWOR TSALL.
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

    # Result text for a single order. Returns the raw text blob or nil
    # if the order is unknown / has no result.
    #
    # Formals: RESULT(REF,DFN,ORID,ID) (ORWOR.m:29-34): DFN builds the
    # patient variable pointer, and ORDERS^ORCXPND1 reads ID as the file
    # 100 IEN (ORCXPND1.m:91). The order IEN fills both ORID and ID. An
    # IEN-only frame put the IEN in DFN and died in M on ID (#259).
    def result(dfn, order_ien)
      return nil if invalid_id?(dfn) || invalid_id?(order_ien)

      text = DataMapper.order_result.fetch_text(dfn.to_s, order_ien.to_s, order_ien.to_s)
      return nil if blank?(text)

      text
    end

    # Historical result observations for an order. Each row hash:
    # { result_datetime:, value:, units:, abnormal_flag:, reference_range:, status: }.
    def result_history(order_ien)
      return [] if invalid_id?(order_ien)

      Array(DataMapper.order_result_history.fetch_many(order_ien.to_s))
    end

    # Free-text describing the user-facing action available on an order.
    # Returns nil if either argument is blank.
    def action_text(order_ien, action_code)
      return nil if invalid_id?(order_ien) || blank?(action_code)

      text = DataMapper.order_action_text.fetch_text(order_ien.to_s, action_code.to_s)
      return nil if blank?(text)

      text
    end

    # True/false for whether an order has expired. Returns nil on
    # invalid input or when the broker returns nothing (unknown order).
    def expired?(order_ien)
      return nil if invalid_id?(order_ien)

      DataMapper.order_expired.fetch_scalar(order_ien.to_s)
    end

    # Order sheets available for a patient (active, delayed release,
    # transfer, etc).
    def sheets_for_patient(dfn)
      return [] if invalid_id?(dfn)

      Array(DataMapper.order_sheets.fetch_many(dfn.to_s))
    end

    # Site-level catalog of order sheets, independent of patient.
    def all_sheets
      Array(DataMapper.order_sheets_all.fetch_many)
    end

    private

    def invalid_id?(value)
      value.nil? || value.to_s.strip.empty? || value.to_i <= 0
    end

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end
  end
end
