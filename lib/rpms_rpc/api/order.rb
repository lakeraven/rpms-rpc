# frozen_string_literal: true

require_relative "../shape"
require_relative "../mappings"

module RpmsRpc
  # Symbolic API for clinical orders — list-side, a patient's orders and
  # the patient's unsigned actions, plus per-order result reads
  # and order-sheet catalog reads for the order-review surface, and
  # filing a new unsigned order. Underlying RPCs (layouts per FOIA
  # ORWOR.m / ORWORR.m, #220, and stock ORWDX.m):
  # ORWOR UNSIGN, ORWORR AGET, ORWOR RESULT,
  # ORWOR RESULT HISTORY, ORWOR ACTION TEXT, ORWOR EXPIRED, ORWOR SHEETS,
  # ORWOR TSALL, ORWDX SAVE.
  module Order
    extend self
    extend Shape::Declarable

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

    # CSTS on the GETFLDS header (ORWORR.m:146,150). A save may leave only
    # unreleased (11) or delayed (10); EN^ORCSAVE does not release
    # (ORWDX.m:128-130). 5 and 6 are the pending and active codes the
    # header's status piece carries when the order has already moved on.
    SAVE_STATUS_UNRELEASED = 11
    SAVE_STATUS_DELAYED = 10
    SAVE_STATUS_NAMES = {
      5 => "PENDING",
      6 => "ACTIVE",
      SAVE_STATUS_DELAYED => "DELAYED",
      SAVE_STATUS_UNRELEASED => "UNRELEASED"
    }.freeze
    # "~IFN;ACT" is piece 1 of GETFLDS (ORWORR.m:150). IFN and ACT are
    # positive canonical integers: no sign, no whitespace, no leading zero.
    SAVE_HEADER_ID = /\A~([1-9]\d*);([1-9]\d*)\z/
    # CSTS, piece 6 (ORWORR.m:146,150). Canonical, so a leading zero is
    # not the integer it looks like ("011" is not status 11).
    SAVE_STATUS = /\A(?:0|[1-9]\d*)\z/
    # "^" is an M piece separator. $C(0) through $C(31) and $C(127) are
    # the controls a dialog name or a response must not carry; $C(30) and
    # $C(31) sit in that range.
    WIRE_CONTROL = /[\x00-\x1f\x7f]/

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
    shape :list, resource: "orders", verb: "GET", path: "/patients/{dfn}/orders"

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
    shape :result, resource: "orders", verb: "GET", path: "/patients/{dfn}/orders/{order_ien}/result"

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
    shape :result_history, resource: "orders", verb: "GET", path: "/patients/{dfn}/orders/{order_ien}/result-history"

    # Free-text describing the user-facing action available on an order.
    # Returns nil if either argument is blank.
    def action_text(order_ien, action_code)
      return nil if invalid_id?(order_ien) || blank?(action_code)

      text = DataMapper.order_action_text.fetch_text(order_ien.to_s, action_code.to_s)
      return nil if blank?(text)

      text
    end
    shape :action_text, resource: "orders", verb: "GET", path: "/orders/{order_ien}/action-text"

    # The date/time (Time) from which to search for expired orders: NOW
    # less the ORWOR EXPIRED ORDERS hours. EXPIRED(ORY) takes no parameter
    # and says nothing about any one order (ORWOR.m:147-150). nil when
    # nothing came back.
    def expired_search_start
      DataMapper.order_expired.fetch_scalar
    end
    shape :expired_search_start, resource: "orders", verb: "GET", path: "/orders/expired-search-start"

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
    shape :sheets_for_patient, resource: "orders", verb: "GET", path: "/patients/{dfn}/orders/sheets"

    # Site-level catalog of order sheets, independent of patient.
    def all_sheets
      Array(DataMapper.order_sheets_all.fetch_many)
    end
    shape :all_sheets, resource: "orders", verb: "GET", path: "/orders/all-sheets"

    # File a new order and leave it unsigned. ORWDX SAVE (SAVE^ORWDX) takes
    # the eleven actuals after REC. Formals (FOIA ORWDX.m:80):
    # SAVE(REC,ORVP,ORNP,ORL,DLG,ORDG,ORIT,ORIFN,ORDIALOG,ORDEA,ORAPPT,ORSRC).
    # The repo's BCER inventory (data/inventories/.../rpc_signatures.txt,
    # bcer-9.0-20261012-e7923a4-ydb) lists OREVTDF as a 13th formal on RPMS
    # too, as WorldVistA ORWDX.m:52 does. Sending eleven actuals leaves that
    # formal undefined. SAVE does not handle it with $G: WorldVistA declares
    # OREVTDF and never reads it, and CivicActions ORWDX.m:80 does not
    # declare it. The $G in the body is S ORSRC=$G(ORSRC) (WorldVistA
    # ORWDX.m:126, CivicActions ORWDX.m:117), which defaults the empty ORSRC
    # this call sends. ORIFN "" is a new order, so EN^ORCSAVE runs and
    # nothing is released (ORWDX.m:128-130). `responses` is the ORDIALOG
    # list as given: [prompt, instance] => value, and word-processing
    # ["WP", prompt, instance, line, 0] => line text.
    #
    # The reply is GETBYIFN^ORWORR (ORWORR.m:139-150): line 1 is
    # "~IFN;ACT^Grp^OrdTm^Strt^Stop^Sts^...". IFN and ACT are positive
    # canonical integers; Sts is canonical (no leading zero). Text lines are
    # "t"-prefixed (ORWORR.m:169); the "t" is removed and a "+" or "*"
    # marker stays (ORWORR.m:167-168). A "|" line ends the text and the "x"
    # lines after it are dropped (ORWORR.m:170-171). A line before "|" that
    # is not "t"-prefixed is malformed. No order leaves REC empty
    # (ORWDX.m:130, ORWORR.m:133 `I 'IFN Q`). Status other than 11 or 10,
    # and any empty or malformed reply, fails closed.
    #
    #   => { success: true, order_id: "IFN;ACT", ien:, status:, text: }
    #   => { success: false, error:, message: }
    def save(dfn, provider_duz, location, order_dialog, responses, display_group: "", quick_order: "")
      error = save_argument_error(dfn, provider_duz, location, order_dialog, responses,
                                  display_group, quick_order)
      return error if error

      # ORVP, ORNP, ORL, DLG, ORDG, ORIT, ORIFN, ORDIALOG, ORDEA, ORAPPT,
      # ORSRC (FOIA ORWDX.m:80). OREVTDF, the 13th formal, is not sent.
      # ORDG and ORIT go as canonical decimal strings. ORIFN stays ""
      # (ORWDX.m:128).
      raw = RpmsRpc.client.call_rpc(
        "ORWDX SAVE",
        positive_id(dfn),
        positive_id(provider_duz),
        positive_id(location),
        order_dialog,
        optional_ien(display_group),
        optional_ien(quick_order),
        "",
        responses,
        "",
        "",
        ""
      )
      parse_save_reply(raw)
    rescue RpmsRpc::Client::FrameTooLongError => e
      # Refused before the frame is written. e.message names the byte limit
      # and does not include the value.
      save_failure(:frame_too_long, e.message)
    end
    shape :save, resource: "orders", verb: "POST", path: "/patients/{dfn}/orders"

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

    def save_argument_error(dfn, provider_duz, location, order_dialog, responses, display_group, quick_order)
      return save_failure(:invalid_argument, "dfn must be a positive canonical integer") unless positive_id(dfn)
      return save_failure(:invalid_argument, "provider_duz must be a positive canonical integer") unless positive_id(provider_duz)
      return save_failure(:invalid_argument, "location must be a positive canonical integer") unless positive_id(location)
      return save_failure(:invalid_argument, "order_dialog must be a non-blank dialog name with no caret, control character, or surrounding whitespace") unless dialog_name?(order_dialog)
      return save_failure(:invalid_argument, "display_group must be empty or a positive canonical integer") if optional_ien(display_group).nil?
      return save_failure(:invalid_argument, "quick_order must be empty or a positive canonical integer") if optional_ien(quick_order).nil?
      return save_failure(:invalid_argument, "responses must be a non-empty ORDIALOG list") unless ordialog_responses?(responses)

      value_error = ordialog_value_error(responses)
      return value_error if value_error
      return save_failure(:invalid_argument, "responses has two keys for one ORDIALOG subscript") if duplicate_ordialog_subscript?(responses)

      nil
    end

    # A canonical positive integer: no sign, no whitespace, no leading zero.
    # Returned as the decimal string the broker literal carries.
    def positive_id(value)
      case value
      when Integer
        value.positive? ? value.to_s : nil
      when String
        value.match?(/\A[1-9]\d*\z/) ? value : nil
      end
    end

    # "" or a positive canonical integer, returned as the decimal string
    # the broker literal carries. ORDG and ORIT are compared as IENs
    # (ORWDX.m:103 `K:'ORDG ORDG K:'ORIT ORIT`).
    def optional_ien(value)
      return "" if value == ""

      positive_id(value)
    end

    def dialog_name?(value)
      value.is_a?(String) && !value.empty? && value == value.strip && !wire_unsafe?(value)
    end

    def wire_unsafe?(value)
      value.include?("^") || value.match?(WIRE_CONTROL)
    end

    # ORDIALOG subscripts are two-level [prompt, instance] or the
    # word-processing node ["WP", prompt, instance, line, 0] (the value at
    # the prompt is the pointer ORDIALOG("WP",prompt,instance)).
    def ordialog_responses?(responses)
      responses.is_a?(Hash) && !responses.empty? && responses.each_key.all? { |key| ordialog_key?(key) }
    end

    def ordialog_key?(key)
      return false unless key.is_a?(Array)

      case key.length
      when 2
        integerish?(key[0]) && integerish?(key[1])
      when 5
        key[0] == "WP" && integerish?(key[1]) && integerish?(key[2]) && integerish?(key[3]) && zero_subscript?(key[4])
      else
        false
      end
    end

    # Integer, or a canonical decimal string ("0" or a non-zero digit run).
    def integerish?(value)
      case value
      when Integer then !value.negative?
      when String then value.match?(/\A(?:0|[1-9]\d*)\z/)
      else false
      end
    end

    def zero_subscript?(value)
      value == 0 || value == "0"
    end

    def ordialog_value_error(responses)
      responses.each_value do |value|
        case value
        when Integer
          next
        when String
          if wire_unsafe?(value)
            return save_failure(:invalid_argument, "response value must not contain a caret or a control character")
          end
        else
          return save_failure(:invalid_argument, "response value must be a string or an integer")
        end
      end
      nil
    end

    # LINST^XWBPRS splices the subscript raw into A_"("_X_")" (XWBPRS.m:152-156):
    # a canonic number stays bare, any other level is quoted, and an Array
    # key's levels are joined with commas. Two Ruby keys can land on one node.
    def duplicate_ordialog_subscript?(responses)
      seen = {}
      responses.each_key do |key|
        subscript = ordialog_subscript(key)
        return true if seen[subscript]

        seen[subscript] = true
      end
      false
    end

    def ordialog_subscript(key)
      key.map { |level| ordialog_subscript_level(level) }.join(",")
    end

    def ordialog_subscript_level(level)
      text = level.to_s
      text.match?(/\A-?(0|[1-9]\d*)(\.\d+)?\z/) ? text : %("#{text.gsub('"', '""')}")
    end

    def parse_save_reply(raw)
      lines = save_reply_lines(raw)
      return save_failure(:empty_reply, "ORWDX SAVE returned no order (ORWDX.m:130, ORWORR.m:133)") if lines == :empty
      return save_failure(:malformed_reply, "ORWDX SAVE reply is not a GETFLDS list (ORWORR.m:139)") if lines.nil?

      header = lines.first.to_s
      pieces = header.split("^", -1)
      id = SAVE_HEADER_ID.match(pieces[0].to_s)
      status_text = pieces[5]
      unless id && status_text.to_s.match?(SAVE_STATUS)
        return save_failure(:malformed_reply, "ORWDX SAVE reply is not a GETFLDS order line (ORWORR.m:150)")
      end

      status = status_text.to_i
      unless status == SAVE_STATUS_UNRELEASED || status == SAVE_STATUS_DELAYED
        name = SAVE_STATUS_NAMES.fetch(status, status.to_s)
        return save_failure(:released, "order status #{status} (#{name}) is not unreleased or delayed (ORWORR.m:150)")
      end

      text = save_order_text(lines.drop(1))
      return save_failure(:malformed_reply, "ORWDX SAVE order text is not t-prefixed (ORWORR.m:169)") if text.nil?

      {
        success: true,
        order_id: "#{id[1]};#{id[2]}",
        ien: id[1].to_i,
        status: status,
        text: text
      }
    end

    # GETFLDS prefixes each order-text line with "t" (ORWORR.m:169) after
    # it may have marked the first line "+" or "*" (ORWORR.m:167-168).
    # "|" ends the text; lines after it ("x" PKI XML, ORWORR.m:170-171)
    # are dropped. A line before "|" without the "t" is not order text.
    def save_order_text(lines)
      text = []
      lines.each do |line|
        row = line.to_s
        break if row == "|"
        return nil unless row.start_with?("t")

        text << row[1..]
      end
      text
    end

    # nil, "" and [] are the empty REC (ORWDX.m:130). A one-element list of
    # a blank line is that same empty string once a transport has boxed it.
    # Anything else that is not a line list is malformed, never a success.
    # Client#split_response chomps the trailing newline, so a trailing
    # empty element is not a line. An empty element between lines stays.
    def save_reply_lines(raw)
      lines = case raw
      when nil
        return :empty
      when String
        return :empty if raw.empty?

        raw.split(/\r?\n/, -1)
      when Array
        raw.dup
      else
        return nil
      end
      lines.pop while lines.last == ""
      return :empty if lines.empty? || lines.all? { |line| line.nil? || line.to_s.strip.empty? }

      lines
    end

    def save_failure(error, message)
      { success: false, error: error, message: message }
    end
  end
end
