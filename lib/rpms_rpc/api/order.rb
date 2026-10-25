# frozen_string_literal: true

require_relative "../shape"
require_relative "../mappings"

module RpmsRpc
  # Symbolic API for clinical orders — list-side, a patient's orders and
  # the patient's unsigned actions, plus per-order result reads,
  # order-sheet catalog reads for the order-review surface, order checks
  # when an order is accepted, and filing a new unsigned order.
  # Underlying RPCs (layouts per FOIA ORWOR.m / ORWORR.m / ORWDXC.m, #220,
  # #454, and stock ORWDX.m):
  # ORWOR UNSIGN, ORWORR AGET, ORWOR RESULT,
  # ORWOR RESULT HISTORY, ORWOR ACTION TEXT, ORWOR EXPIRED, ORWOR SHEETS,
  # ORWOR TSALL, ORWDXC ACCEPT, ORWDX SAVE.
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

    # CDL on a CHK2LST row (ORKCHK.m:114-115). 99, blank, or anything else
    # is unknown (ORCHECK.m:88) and requires an override, as does high.
    CDL_SEVERITY = {
      "1" => :high,
      "2" => :moderate,
      "3" => :low
    }.freeze

    # ORKCHK.m:20-21 writes ^^^Order Checking Unavailable - ... (the text
    # is the reason). CHK2LST drops a row whose raw CDL piece is blank
    # (FOIA ORWDXC.m:145, stock WorldVistA ORWDXC.m:151), so that row
    # normally never reaches the wire. The fail-closed branch in
    # parse_chk2lst_row is defensive for a row that does. The reported
    # reason is "order checks unavailable: " plus that server text.
    ORDER_CHECKING_UNAVAILABLE = "Order Checking Unavailable"

    # FDBDOWN^ORCHECK (WorldVistA ORCHECK.m:192-199) writes this sentence
    # when drug checks did not run. Matched at any check ien or CDL.
    INCOMPLETE_CHECK_TEXT = "These checks could not be completed for this patient:"

    # CHKRMT^ORKCHK (WorldVistA ORKCHK.m:133-144) emits this on ACCEPT for
    # PS/RA when remote data is missing. RETURN^ORCHECK keeps pieces 2-4,
    # and CHK2LST parks check ien 99 in the RDI slot (WorldVistA
    # ORWDXC.m:149,152).
    REMOTE_ORDER_CHECKING_UNAVAILABLE = "Remote Order Checking not available"

    # ||<key>&<line> (WorldVistA ORCHECK.m:199). Key is up to the first &.
    EXTENDED_TEXT = /\A\|\|([^&]*)&(.*)\z/

    # DFN, location, and the orderable-item pointer. No sign, suffix, or
    # leading zero. invalid_id? is looser and stays shared by other methods.
    CANONICAL_ID = /\A[1-9]\d*\z/

    # Filler namespace spliced into a |-delimited ORX record
    # (WorldVistA ORWDXC.m:38,47).
    CANONICAL_FILLER_ID = /\A[A-Z][A-Z0-9]*\z/

    # OIL package piece (USID^ORWDXC, WorldVistA ORWDXC.m:110-125).
    CANONICAL_PACKAGE = /\A[A-Z][A-Z0-9]*\z/

    # FOIA ORWDXC.m:39 builds "A" (additive) or "B;<volume>". "B" alone is
    # the TYPE piece USID reads before the semicolon. Volume is free dialog
    # text; stock passes it unchanged to ENDDIV^PSJORUTL (WorldVistA
    # ORWDXC.m:117-119). A volume is non-empty and contains neither "|"
    # nor "^".
    PSIV_PKGINFO = /\A(?:A|B|B;[^|^]+)\z/

    # OPOS^ORWDXC (WorldVistA ORWDXC.m:53,214-229) shows the incomplete
    # banner once per broker job and then deletes it, so a later ACCEPT
    # for that patient can look complete. This memo copies that for one
    # client object: a DFN sticks when a raw reply line carries the
    # incomplete-checks banner or the remote-checking row (check ien 99,
    # or that sentence), even if the reply fails closed. An empty reply
    # does not. RpcError and ParseError from ORWDXC ACCEPT stick the DFN
    # too; a timeout or connection error does not. The memo is keyed in
    # an ObjectSpace::WeakKeyMap, which compares keys with eql? and hash,
    # not strict object identity, and holds the key weakly so a discarded
    # client can be collected. The value is a Hash of DFN strings and must
    # not reference the client.
    # A different DFN starts clean, as does a client that is not eql? to
    # the one that recorded the banner.
    #
    # The incomplete-checks memory follows the client object, so a host
    # must reuse one client object per broker connection. A fresh wrapper
    # per request around a shared connection loses it, and OPOS then hides
    # the banner (ORWDXC.m:53,214-229).
    #
    # check holds RpmsRpc.synchronize_wire across the ACCEPT call_rpc and
    # the memo update. That is the client's reentrant Monitor when the
    # client defines #synchronize_wire, otherwise MODULE_WIRE_LOCK — the
    # same lock call_rpc takes, so there is one lock order with the
    # client's wire lock. Nested use reenters, including from inside a
    # host's synchronize_wire sequence, instead of deadlocking on a
    # second mutex. Two checks on that client run in the order the
    # broker ran them. SESSION_INCOMPLETE guards the WeakKeyMap only and
    # is never held while calling the RPC.
    #
    # A reconnect on the same client object over-reports. The new broker
    # job has an empty OPOS global, and this memo still says the DFN was
    # incomplete. That errs safe: the result stays incomplete and still
    # requires an override.
    SESSION_INCOMPLETE = Mutex.new
    SESSION_INCOMPLETE_DFNS = ObjectSpace::WeakKeyMap.new
    SESSION_INCOMPLETE_REASON =
      "order checks were reported incomplete earlier in this broker session"
    private_constant :SESSION_INCOMPLETE, :SESSION_INCOMPLETE_DFNS, :SESSION_INCOMPLETE_REASON

    # One CHK2LST row: ORID^checkIEN^CDL^text (FOIA ORWDXC.m:138-147,
    # stock WorldVistA ORWDXC.m:128-154). check_ien is the ORDER CHECKS
    # (#100.8) pointer, the check type. ||<key>&<line> stores <line> as
    # text and <key> as extended_text_key; plain text has a nil key.
    # Incomplete when the text is the FDBDOWN banner, the check ien is
    # "99", or the text starts with the CHKRMT remote-checking sentence.
    Check = Data.define(:order_id, :check_ien, :severity, :text, :extended_text_key) do
      def incomplete?
        check_ien == "99" ||
          text.start_with?(REMOTE_ORDER_CHECKING_UNAVAILABLE) ||
          text.include?(INCOMPLETE_CHECK_TEXT)
      end

      def override_required?
        severity == :high || severity == :unknown || incomplete?
      end
    end

    # Whole ACCEPT reply. Unavailable results have no checks; an empty or
    # unreadable reply cannot be told from a failure, so it fails closed.
    # complete? is false when the reply is unavailable, any check is
    # incomplete, or this client already saw an incomplete check for the
    # same DFN (the OPOS memo above). incomplete_reason names those checks,
    # or names that order checks were reported incomplete earlier in this
    # broker session. It is nil when the result is complete, and nil when
    # the reply is unavailable (that case uses unavailable_reason).
    # override_required? is true whenever the result is not complete, and
    # also for a high or unknown check.
    CheckResult = Data.define(:available, :unavailable_reason, :checks, :incomplete_reason) do
      def self.ready(checks, incomplete_reason: nil)
        new(available: true, unavailable_reason: nil, checks: checks.freeze,
            incomplete_reason: incomplete_reason&.freeze)
      end

      def self.unavailable(reason)
        new(available: false, unavailable_reason: reason.to_s.freeze, checks: [].freeze,
            incomplete_reason: nil)
      end

      def available? = available

      def complete?
        available && incomplete_reason.nil? && checks.none?(&:incomplete?)
      end

      def override_required?
        !complete? || checks.any?(&:override_required?)
      end
    end

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

    # Order checks for orderables being accepted.
    #
    # ACCEPT(LST,DFN,FID,STRT,ORL,OIL,ORIFN) (FOIA-RPMS ORWDXC.m:45). Stock
    # VistA adds an unread eighth formal ORREN (WorldVistA ORWDXC.m:23); the
    # seven shared parameters are what is sent. FID is the filler namespace
    # from FILLID^ORWDXC (ORWDXC.m:7-16), spliced into a |-delimited record
    # (WorldVistA ORWDXC.m:38,47). OIL(n) is OIptr^PKG^PkgInfo (ORWDXC.m:46),
    # indexed from 1; the package and PkgInfo are checked as USID^ORWDXC
    # reads them (WorldVistA ORWDXC.m:110-125). ORIFN is the existing order,
    # or "" for a new one. STRT may be empty. DFN, FID, location, and each
    # orderable are checked before any RPC; a bad argument comes back
    # unavailable.
    #
    # Stock ACCEPT adds REMDUPS, FDBDOWN, OPOS, and CHECKIT (WorldVistA
    # ORWDXC.m:52-55,128-154). OPOS writes ^TMP($J,"OC-OPOS",DFN)
    # (WorldVistA ORWDXC.m:53,214-229) and drops the incomplete-checks
    # banner on a later ACCEPT in that broker job. check is a
    # non-idempotent write because of that session write. The same client
    # object remembers a DFN when the raw lines carry the incomplete-checks
    # banner or the remote-checking row, including a reply that fails
    # closed. An empty reply does not. The rescue that records the DFN
    # before re-raising skips RpcRefusedError and RpcNotAvailableError.
    # Those mean the routine never ran, so OPOS did not run. RpcMError,
    # other RpcError, and ParseError still record the DFN. Every error is
    # re-raised. OPOS runs before CHK2LST (ORWDXC.m:53-55), so the banner
    # may already be suppressed when the routine did run. TimeoutError and
    # ConnectionError do not remember the DFN. The incomplete-checks memory
    # follows the client object, so a host must reuse one client object per
    # broker connection. A fresh wrapper per request around a shared connection
    # loses it, and OPOS then hides the banner (ORWDXC.m:53,214-229).
    # Later results for that DFN stay incomplete. The ACCEPT call and the
    # memo update share
    # RpmsRpc.synchronize_wire (one lock order with the client's wire
    # lock; reentrant from inside a host's synchronize_wire sequence),
    # so the memo follows the order the broker ran them. A reconnect on
    # that object over-reports, which errs safe: the new job has forgotten
    # the banner, and this side still refuses to call the checks complete.
    #
    # CHK2LST answers ORID^checkIEN^CDL^text (FOIA ORWDXC.m:138-147, stock
    # WorldVistA ORWDXC.m:128-154). Rows are split on CRLF, a bare CR, or
    # LF, and only those separators are dropped. A row that still contains
    # a control character, or bytes that are not valid UTF-8, fails the
    # whole result closed ("malformed reply"). valid_encoding? is checked
    # before every regex on reply text: match? and split raise
    # ArgumentError on those bytes.
    # check_ien is the ORDER CHECKS (#100.8) pointer, the check type.
    # CHK2LST drops a row whose raw CDL piece is
    # blank (FOIA ORWDXC.m:145, stock :151), so the in-band Order Checking
    # Unavailable rows (ORKCHK.m:20-21) normally never reach the wire; one
    # that does still fails the whole result closed, with reason
    # "order checks unavailable: " plus the server text. An empty reply
    # cannot be told from a failure, so it is unavailable — never "no
    # checks found". Any malformed row fails closed. RpcMError, other
    # RpcError, and ParseError from ACCEPT propagate after the DFN is
    # remembered. RpcRefusedError and RpcNotAvailableError propagate
    # without that memo: the routine never ran, so OPOS did not run.
    # Every error is re-raised. Timeout and connection errors propagate
    # without that memo.
    def check(dfn, filler_id:, location:, items:, start: "", order_id: nil)
      return check_unavailable("invalid patient id") unless strict_positive_id?(dfn)
      return check_unavailable("invalid filler id") unless canonical_filler_id?(filler_id)
      return check_unavailable("invalid location") unless strict_positive_id?(location)

      oil = oil_list(items)
      return check_unavailable(oil) if oil.is_a?(String)

      client = RpmsRpc.client
      # Wire lock, then the memo mutex: the same lock call_rpc takes, so a
      # host already inside synchronize_wire reenters instead of inverting
      # lock order. SESSION_INCOMPLETE stays off the RPC itself.
      RpmsRpc.synchronize_wire do
        reply = client.call_rpc("ORWDXC ACCEPT", dfn.to_s, filler_id.to_s, start.to_s,
                                location.to_s, oil, order_id.to_s)
        parse_accept_reply(reply, client, dfn.to_s)
      rescue RpmsRpc::Client::RpcRefusedError, RpmsRpc::Client::RpcNotAvailableError
        # Subclasses of RpcError, so this clause must come first. The routine
        # never ran, so OPOS did not run. Re-raise without recording the DFN.
        raise
      rescue RpmsRpc::Client::RpcError, RpmsRpc::Client::ParseError
        # RpcMError, other RpcError, and ParseError still record the DFN, then re-raise.
        remember_incomplete_dfn(client, dfn.to_s)
        raise
      end
    end
    shape :check, resource: "orders", verb: "POST", path: "/patients/{dfn}/orders/check"

    private

    # GET1^ORWORR1 sets the .1 node to TOT^TXTVW^ORYD (ORWORR1.m:13), and
    # .1 collates before every row, so the first line is never an order.
    def drop_aget_header(reply)
      return [] if reply.nil? || reply.empty?

      lines = reply.is_a?(String) ? reply.split(/\r?\n/) : Array(reply)
      lines.drop(1)
    end

    # Shared by the other Order reads. to_i accepts a trailing suffix
    # ("8791abc"); those methods keep this. Order.check does not.
    def invalid_id?(value)
      value.nil? || value.to_s.strip.empty? || value.to_i <= 0
    end

    # ACCEPT DFN and ORL. A positive Integer, or a canonical digit string.
    def strict_positive_id?(value)
      case value
      when Integer
        value > 0
      when String
        value.match?(CANONICAL_ID)
      else
        false
      end
    end

    def canonical_filler_id?(value)
      value.is_a?(String) && value.match?(CANONICAL_FILLER_ID)
    end

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end

    def check_unavailable(why)
      CheckResult.unavailable("order checks unavailable: #{why}")
    end

    # Strings pass through as OIL rows. Hashes are OIptr^PKG^PkgInfo
    # (ORWDXC.m:46). The orderable pointer (first ^ piece, or
    # :orderable_item) must be a canonical id: stock ACCEPT skips a
    # non-numeric OIL (WorldVistA ORWDXC.m:35,45) and would still report
    # the other items. The package piece must be present and match
    # CANONICAL_PACKAGE. A package starting with "PS" other than "PSIV"
    # needs a positive-integer PkgInfo; "PSIV" needs PSIV_PKGINFO; any
    # other package takes any PkgInfo. No piece may contain "|", because
    # those pieces are spliced into a |-delimited record (WorldVistA
    # ORWDXC.m:38,47). Returns the rows, or a reason string when the list
    # cannot be sent. String and hash items use the same rules.
    def oil_list(items)
      return "no orderable items" unless items.is_a?(Array) && !items.empty?

      rows = items.map { |item| oil_row(item) }
      return "invalid orderable item" if rows.any?(&:nil?)

      rows
    end

    def oil_row(item)
      case item
      when String
        string_oil_row(item)
      when Hash
        hash_oil_row(item)
      end
    end

    def string_oil_row(item)
      return nil if item.strip.empty?

      pieces = item.split("^", -1)
      return nil unless acceptable_oil_pieces?(pieces)

      item
    end

    def hash_oil_row(item)
      pieces = [
        hash_field(item, :orderable_item),
        hash_field(item, :package),
        hash_field(item, :package_info)
      ]
      return nil unless acceptable_oil_pieces?(pieces)

      pieces.join("^")
    end

    # USID^ORWDXC (WorldVistA ORWDXC.m:110-125). A PS-family package other
    # than PSIV uses ORDRUG=+$P(OIL,U,3); a non-numeric PkgInfo becomes 0
    # and the drug identity is blank. PSIV is "A", "B", or "B;" plus a
    # non-empty volume with neither "|" nor "^" (PSIV_PKGINFO).
    def acceptable_oil_pieces?(pieces)
      return false if pieces.any? { |piece| piece.to_s.include?("|") }
      return false unless pieces[0].to_s.match?(CANONICAL_ID)

      package = pieces[1].to_s
      return false unless package.match?(CANONICAL_PACKAGE)

      # "^" splits the row. A PSIV volume is everything after the package,
      # so a caret inside it is still visible to PSIV_PKGINFO.
      pkginfo = package == "PSIV" ? pieces.drop(2).join("^") : pieces[2].to_s
      acceptable_pkginfo?(package, pkginfo)
    end

    def acceptable_pkginfo?(package, pkginfo)
      if package == "PSIV"
        pkginfo.match?(PSIV_PKGINFO)
      elsif package.start_with?("PS")
        pkginfo.match?(CANONICAL_ID)
      else
        true
      end
    end

    def hash_field(item, key)
      value = item.key?(key) ? item[key] : item[key.to_s]
      value.to_s
    end

    # A control character, or bytes that are not valid UTF-8. match? raises
    # ArgumentError on the latter, so valid_encoding? comes first. The
    # caller fails the reply closed ("malformed reply").
    def unreadable_reply_line?(line)
      text = line.to_s
      return true unless text.valid_encoding?

      text.match?(/[[:cntrl:]]/)
    end

    def parse_accept_reply(reply, client, dfn)
      lines = accept_lines(reply)
      # A control character, or bytes that are not valid UTF-8, left after
      # the line breaks are removed makes the reply unreadable
      # ("malformed reply"), ahead of the empty-reply and Order Checking
      # Unavailable paths. valid_encoding? runs before the control regexp.
      # A banner on those lines is still remembered.
      controlled = lines.any? { |line| unreadable_reply_line?(line) }
      return check_unavailable("empty reply") if !controlled && blank_reply?(lines)

      rows = lines.map { |line| parse_chk2lst_row(line) }
      reason = controlled ? "malformed reply" : rows.find { |row| row.is_a?(String) }
      if reason || rows.any?(&:nil?)
        remember_incomplete_dfn(client, dfn) if lines.any? { |line| incomplete_raw_line?(line) }
        return check_unavailable(reason || "malformed reply")
      end

      CheckResult.ready(rows, incomplete_reason: apply_session_incomplete(client, dfn, rows))
    end

    # Banner text, or the remote-checking row: check ien 99, or the
    # CHKRMT sentence. An empty line is neither.
    def incomplete_raw_line?(line)
      text = line.to_s
      return true if text.include?(INCOMPLETE_CHECK_TEXT)
      return true if text.include?(REMOTE_ORDER_CHECKING_UNAVAILABLE)
      # The caret split is a regexp scan and raises ArgumentError on
      # bytes that are not valid UTF-8. include? above is not.
      return false unless text.valid_encoding?

      text.split("^", 3)[1] == "99"
    end

    def remember_incomplete_dfn(client, dfn)
      SESSION_INCOMPLETE.synchronize { write_incomplete_dfn(client, dfn) }
    end

    # Nil when this reply is complete. A reply that itself has an
    # incomplete check is remembered for (client, dfn) and names those
    # checks. A later reply for that pair names the earlier report.
    # Read and written under SESSION_INCOMPLETE only. That mutex guards
    # the WeakKeyMap and is never held while calling the RPC; the wire
    # lock is already held by check.
    def apply_session_incomplete(client, dfn, checks)
      SESSION_INCOMPLETE.synchronize do
        if checks.any?(&:incomplete?)
          write_incomplete_dfn(client, dfn)
          incomplete_check_reason(checks)
        elsif SESSION_INCOMPLETE_DFNS[client]&.key?(dfn)
          SESSION_INCOMPLETE_REASON
        end
      end
    end

    # Caller holds SESSION_INCOMPLETE.
    def write_incomplete_dfn(client, dfn)
      noted = SESSION_INCOMPLETE_DFNS[client]
      noted ||= {}
      noted[dfn] = true
      SESSION_INCOMPLETE_DFNS[client] = noted
    end

    def incomplete_check_reason(checks)
      named = checks.select(&:incomplete?).map { |check| "#{check.check_ien} #{check.text}" }
      "incomplete order checks: #{named.join("; ")}"
    end

    def blank_reply?(lines)
      lines.empty? || lines.all? { |line| line.valid_encoding? && line.strip.empty? }
    end

    # YDB writes CHK2LST rows separated by a bare CR. XWB split_response
    # (client.rb) returns that as one String when the reply has no LF, and
    # an Array element can carry the same breaks. Split a String reply, and
    # each Array element, on CRLF, bare CR, or LF. Only those separators
    # are dropped. An empty element is kept: it is a blank row, not a break.
    # A line that is not valid UTF-8 is not split: the regexp raises
    # ArgumentError. It stays one row for the malformed-reply path.
    def accept_lines(reply)
      case reply
      when nil
        []
      when String
        split_reply_rows(reply)
      else
        Array(reply).flat_map { |line| split_reply_rows(line.to_s) }
      end
    end

    def split_reply_rows(text)
      return [ text ] if text.empty? || !text.valid_encoding?

      text.split(/\r\n|\r|\n/)
    end

    # nil is a malformed row (the whole reply then fails closed). A String
    # is the Order Checking Unavailable server text (ORKCHK.m:20-21);
    # the caller prefixes "order checks unavailable: ". CHK2LST drops a
    # blank raw CDL piece before such a row would be sent (FOIA
    # ORWDXC.m:145, stock WorldVistA ORWDXC.m:151); failing closed here
    # is defensive. Check ien 99 is the CHKRMT remote-checking row, a
    # real check, not this sentinel. A control character still in the row
    # after the line breaks are removed is malformed ("malformed reply").
    # Bytes that are not valid UTF-8 are malformed the same way.
    def parse_chk2lst_row(line)
      row = line.to_s
      # valid_encoding? before the control regexp and the caret split.
      return nil if unreadable_reply_line?(row)

      pieces = row.split("^", 4)
      return nil if pieces.length < 4

      order_id, check_ien, cdl, raw_text = pieces
      return raw_text if raw_text.to_s.lstrip.start_with?(ORDER_CHECKING_UNAVAILABLE)

      ien = check_ien.to_s
      return nil unless ien.valid_encoding? && ien.match?(/\A\d+\z/)

      text, extended_key = split_extended_text(raw_text)
      Check.new(
        order_id: order_id.to_s.freeze,
        check_ien: ien.freeze,
        severity: CDL_SEVERITY.fetch(cdl.to_s, :unknown),
        text: text.freeze,
        extended_text_key: extended_key&.freeze
      )
    end

    def split_extended_text(raw)
      text = raw.to_s
      return [ text, nil ] unless text.valid_encoding?

      match = EXTENDED_TEXT.match(text)
      return [ text, nil ] unless match

      [ match[2], match[1] ]
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
