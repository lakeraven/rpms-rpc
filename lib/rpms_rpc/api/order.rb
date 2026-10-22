# frozen_string_literal: true

require_relative "../mappings"

module RpmsRpc
  # Symbolic API for clinical orders — list-side, a patient's orders and
  # the patient's unsigned actions, plus per-order result reads,
  # order-sheet catalog reads for the order-review surface, and order
  # checks when an order is accepted.
  # Underlying RPCs (layouts per FOIA ORWOR.m / ORWORR.m / ORWDXC.m, #220, #454):
  # ORWOR UNSIGN, ORWORR AGET, ORWOR RESULT,
  # ORWOR RESULT HISTORY, ORWOR ACTION TEXT, ORWOR EXPIRED, ORWOR SHEETS,
  # ORWOR TSALL, ORWDXC ACCEPT.
  module Order
    extend self

    # Order view ids from ORDSTS^ORCHANG2 (ORCHANG2.m:37-63), which AGET
    # takes as FILTER (ORWORR.m:25,34) -- the list REVSTS^ORWORDG serves.
    FILTER_IDS = {
      all:                              "1",
      active:                           "2",
      current:                          "23",
      discontinued:                     "3",
      discontinued_or_entered_in_error: "28",
      completed_or_expired:             "4",
      expiring:                         "5",
      pending:                          "7",
      on_hold:                          "18",
      new:                              "19",
      unsigned:                         "11",
      unverified:                       "8",
      unverified_by_nursing:            "9",
      unverified_by_clerk:              "10",
      unverified_chart_review:          "20",
      verbal:                           "13",
      verbal_unsigned:                  "14",
      flagged:                          "12",
      recent_activity:                  "6",
      delayed:                          "24",
      delayed_admission:                "15",
      delayed_transfer:                 "17",
      delayed_discharge:                "16",
      delayed_return_from_or:           "25",
      delayed_manual_release:           "26",
      lapsed:                           "22"
    }.freeze

    # AGET's own default display group (ORWORR.m:33).
    DEFAULT_DISPLAY_GROUP = 1

    # CDL on a CHK2LST row (ORKCHK.m:114-115). 99, blank, or anything else
    # is unknown (ORCHECK.m:88) and requires an override, as does high.
    CDL_SEVERITY = {
      "1" => :high,
      "2" => :moderate,
      "3" => :low
    }.freeze

    # ORKCHK.m:20-21. After RETURN^ORCHECK the row is
    # NEW^^99^Order Checking Unavailable - ... (the text is the reason).
    ORDER_CHECKING_UNAVAILABLE = "Order Checking Unavailable"

    # One CHK2LST row: ORID^checkIEN^CDL^text (ORWDXC.m:138-147).
    Check = Data.define(:order_id, :check_ien, :severity, :text) do
      def override_required? = severity == :high || severity == :unknown
    end

    # Whole ACCEPT reply. Unavailable results have no checks; an empty or
    # unreadable reply cannot be told from a failure, so it fails closed.
    CheckResult = Data.define(:available, :unavailable_reason, :checks) do
      def self.ready(checks)
        new(available: true, unavailable_reason: nil, checks: checks.freeze)
      end

      def self.unavailable(reason)
        new(available: false, unavailable_reason: reason.to_s.freeze, checks: [].freeze)
      end

      def available? = available

      def override_required?
        !available || checks.any?(&:override_required?)
      end
    end

    # The patient's unsigned order actions the signed-on user may sign.
    # Each row: { order_id: "IFN;ACT", ien:, action_ien: }.
    #
    # UNSIGN(LST,ORVP,HAVE) (ORWOR.m:114) takes the PATIENT; the user is the
    # session DUZ. It answers nothing when that user lacks ORES (ORWOR.m:116)
    # or OR UNSIGNED ORDERS ON EXIT is off (ORWOR.m:120), which reads the
    # same as "none unsigned".
    def unsigned_for_patient(dfn)
      return [] if invalid_id?(dfn)

      Array(DataMapper.orders_unsigned.fetch_many(dfn.to_s)).map do |row|
        ien, action = row[:order_id].to_s.split(";", 2)
        { order_id: row[:order_id], ien: ien.to_i, action_ien: action.to_i }
      end
    end

    # A patient's orders under one ORCHANG2 view (FILTER_IDS) and display
    # group (a file 100.98 IEN). Each row:
    # { order_id: "IFN;ACT", ien:, display_group_ien:, action_datetime:,
    #   event_ien:, event_name: } (ORWORR1.m:11). No order text: AGET does
    # not return it.
    def list(dfn, filter: :active, display_group: DEFAULT_DISPLAY_GROUP)
      return [] if invalid_id?(dfn)

      filter_id = FILTER_IDS[filter]
      raise ArgumentError, "unknown filter: #{filter.inspect}" if filter_id.nil?

      reply = RpmsRpc.client.call_rpc(DataMapper.orders_list.rpc_name,
                                      dfn.to_s, filter_id, display_group.to_s)
      DataMapper.orders_list.parse_many(drop_aget_header(reply))
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

    # Result history report for an order: the formatted text ORDHIST^ORWOR2
    # writes, or nil when the order is unknown or nothing came back.
    # Formals: RESHIST(REF,DFN,ORID,ID) (ORWOR.m:36), the same as RESULT, so
    # the order IEN fills ORID and ID (ORWOR2.m:7 reads +ID).
    def result_history(dfn, order_ien)
      return nil if invalid_id?(dfn) || invalid_id?(order_ien)

      text = DataMapper.order_result_history.fetch_text(dfn.to_s, order_ien.to_s, order_ien.to_s)
      return nil if blank?(text)

      text
    end

    # Free-text describing the user-facing action available on an order.
    # Returns nil if either argument is blank.
    def action_text(order_ien, action_code)
      return nil if invalid_id?(order_ien) || blank?(action_code)

      text = DataMapper.order_action_text.fetch_text(order_ien.to_s, action_code.to_s)
      return nil if blank?(text)

      text
    end

    # The date/time (Time) from which to search for expired orders: NOW
    # less the ORWOR EXPIRED ORDERS hours. EXPIRED(ORY) takes no parameter
    # and says nothing about any one order (ORWOR.m:147-150). nil when
    # nothing came back.
    def expired_search_start
      DataMapper.order_expired.fetch_scalar
    end

    # Order sheets for a patient (current view, admit/transfer/discharge
    # delayed-order events). Each row:
    # { sheet_id: "TYPE;ID", event_type:, event_ref:, label: }
    # (ORWOR.m:97-105). sheet_id is the composite the client sends back.
    def sheets_for_patient(dfn)
      return [] if invalid_id?(dfn)

      Array(DataMapper.order_sheets.fetch_many(dfn.to_s)).map do |row|
        type, ref = row[:sheet_id].to_s.split(";", 2)
        { sheet_id: row[:sheet_id], event_type: type, event_ref: ref, label: row[:label] }
      end
    end

    # Site-level catalog of order sheets, independent of patient.
    def all_sheets
      Array(DataMapper.order_sheets_all.fetch_many)
    end

    # Order checks for orderables being accepted.
    #
    # ACCEPT(LST,DFN,FID,STRT,ORL,OIL,ORIFN) (FOIA-RPMS ORWDXC.m:45). Stock
    # VistA adds an unread eighth formal ORREN (ORWDXC.m:23); the seven
    # shared parameters are what is sent. FID is the filler namespace from
    # FILLID^ORWDXC (ORWDXC.m:7-16). OIL(n) is OIptr^PKG^PkgInfo
    # (ORWDXC.m:46), indexed from 1. ORIFN is the existing order, or "" for
    # a new one. STRT may be empty.
    #
    # CHK2LST answers ORID^checkIEN^CDL^text (ORWDXC.m:138-147). An empty
    # reply cannot be told from a failure, so it is unavailable — never
    # "no checks found". An in-band Order Checking Unavailable row
    # (ORKCHK.m:20-21) or any malformed row fails the whole result closed.
    # Broker errors propagate.
    def check(dfn, filler_id:, location:, items:, start: "", order_id: nil)
      return check_unavailable("invalid patient id") if invalid_id?(dfn)
      return check_unavailable("invalid filler id") if blank?(filler_id)
      return check_unavailable("invalid location") if invalid_id?(location)

      oil = oil_list(items)
      return check_unavailable("no orderable items") if oil.nil?

      reply = RpmsRpc.client.call_rpc("ORWDXC ACCEPT", dfn.to_s, filler_id.to_s, start.to_s,
                                      location.to_s, oil, order_id.to_s)
      parse_accept_reply(reply)
    end

    private

    # GET1^ORWORR1 sets the .1 node to TOT^TXTVW^ORYD (ORWORR1.m:13), and
    # .1 collates before every row, so the first line is never an order.
    def drop_aget_header(reply)
      return [] if reply.nil? || reply.empty?

      lines = reply.is_a?(String) ? reply.split(/\r?\n/) : Array(reply)
      lines.drop(1)
    end

    def invalid_id?(value)
      value.nil? || value.to_s.strip.empty? || value.to_i <= 0
    end

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end

    def check_unavailable(why)
      CheckResult.unavailable("order checks unavailable: #{why}")
    end

    # Strings pass through as OIL rows. Hashes are OIptr^PKG^PkgInfo
    # (ORWDXC.m:46). Anything else, or an empty list, is not a frame.
    def oil_list(items)
      return nil unless items.is_a?(Array) && !items.empty?

      rows = items.map { |item| oil_row(item) }
      return nil if rows.any?(&:nil?)

      rows
    end

    def oil_row(item)
      case item
      when String
        item.strip.empty? ? nil : item
      when Hash
        orderable = hash_field(item, :orderable_item)
        return nil if orderable.strip.empty?

        "#{orderable}^#{hash_field(item, :package)}^#{hash_field(item, :package_info)}"
      end
    end

    def hash_field(item, key)
      value = item.key?(key) ? item[key] : item[key.to_s]
      value.to_s
    end

    def parse_accept_reply(reply)
      lines = accept_lines(reply)
      return check_unavailable("empty reply") if blank_reply?(lines)

      rows = lines.map { |line| parse_chk2lst_row(line) }
      reason = rows.find { |row| row.is_a?(String) }
      return CheckResult.unavailable(reason) if reason
      return check_unavailable("malformed reply") if rows.any?(&:nil?)

      CheckResult.ready(rows)
    end

    def blank_reply?(lines)
      lines.empty? || lines.all? { |line| line.strip.empty? }
    end

    def accept_lines(reply)
      case reply
      when nil
        []
      when String
        return [] if reply.strip.empty?

        reply.split(/\r?\n/)
      else
        Array(reply).map { |line| line.to_s.delete_suffix("\r") }
      end
    end

    # nil is a malformed row (the whole reply then fails closed). A String
    # is the Order Checking Unavailable reason (ORKCHK.m:20-21).
    def parse_chk2lst_row(line)
      pieces = line.to_s.split("^", 4)
      return nil if pieces.length < 4

      order_id, check_ien, cdl, text = pieces
      return text if text.to_s.lstrip.start_with?(ORDER_CHECKING_UNAVAILABLE)

      ien = check_ien.to_s
      return nil unless ien.match?(/\A\d+\z/)

      Check.new(
        order_id: order_id.to_s.freeze,
        check_ien: ien.freeze,
        severity: CDL_SEVERITY.fetch(cdl.to_s, :unknown),
        text: text.to_s.freeze
      )
    end
  end
end
